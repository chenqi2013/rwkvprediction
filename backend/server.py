"""AKShare market API with simulated forecasts and local delivery receipts.

Run: python3 backend/server.py --port 8787
Forecasts are synthetic. No external notification is sent by delivery endpoints.
"""
import argparse
import json
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote
from market_provider import MarketProvider, MarketUnavailable
from instrument_catalog import InstrumentCatalog, CatalogUnavailable, instrument

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'rwkvprediction/rwkvprediction/Resources/market-demo.json'
DB = Path(__file__).with_name('deliveries.sqlite3')


def payload():
    return json.loads(FIXTURES.read_text())


PROVIDER = MarketProvider(payload())


@contextmanager
def connect():
    connection = sqlite3.connect(DB)
    try:
        with connection:
            connection.execute('CREATE TABLE IF NOT EXISTS deliveries (id TEXT PRIMARY KEY, receipt TEXT NOT NULL)')
            connection.execute('CREATE TABLE IF NOT EXISTS forecasts (id TEXT PRIMARY KEY, snapshot TEXT NOT NULL)')
            yield connection
    finally:
        connection.close()


def save_snapshot(snapshot):
    encoded = json.dumps(snapshot, ensure_ascii=False)
    with connect() as connection:
        for forecast in snapshot['predictions'].values():
            connection.execute('INSERT OR IGNORE INTO forecasts VALUES (?, ?)', (forecast['id'], encoded))
    return snapshot


def make_delivery(body):
    if not isinstance(body, dict):
        raise ValueError('JSON object required')
    symbol = body.get('symbol')
    channel = body.get('channel')
    prediction_id = body.get('prediction_id')
    confidence = body.get('confidence', 80)
    if type(confidence) is not int or confidence not in (80, 95):
        raise ValueError('confidence must be 80 or 95')
    if not isinstance(symbol, str):
        raise ValueError('Unknown symbol')
    if not isinstance(prediction_id, str):
        raise ValueError('prediction_id must be a string')
    with connect() as connection:
        saved = connection.execute('SELECT snapshot FROM forecasts WHERE id = ?', (prediction_id,)).fetchone()
    snapshot = json.loads(saved[0]) if saved else None
    if snapshot is None and PROVIDER.mode == 'demo' and symbol in PROVIDER.fixtures['snapshots']:
        snapshot = PROVIDER.fixtures['snapshots'][symbol]
    requested_id = body.get('instrument_id', symbol)
    saved_asset = snapshot['asset'] if snapshot else {}
    saved_identity = None
    if snapshot:
        saved_identity = saved_asset.get('id') or instrument(saved_asset['symbol'], saved_asset['name'], saved_asset['kind'])['id']
    identity_matches = requested_id == saved_identity if 'instrument_id' in body else requested_id == saved_asset.get('symbol')
    if not snapshot or symbol != saved_asset.get('symbol') or not identity_matches or prediction_id not in [f['id'] for f in snapshot['predictions'].values()]:
        raise ValueError('Prediction does not belong to this symbol')
    if channel not in ('in_app', 'webhook_demo'):
        raise ValueError('channel must be in_app or webhook_demo')
    forecast = next(f for f in snapshot['predictions'].values() if f['id'] == prediction_id)
    end = forecast['points'][-1]
    saved_forecast = dict(horizon=forecast['horizon'], confidence=confidence,
                          lower=end['p025' if confidence == 95 else 'p10'], median=end['p50'],
                          upper=end['p975' if confidence == 95 else 'p90'], currency='CNY',
                          decimals=3 if snapshot['asset']['kind'] == 'ETF' else 2, explanation=forecast['explanation'],
                          market_source=snapshot['source'], as_of=snapshot['as_of'])
    receipt = dict(id=str(uuid.uuid4()), prediction_id=prediction_id, symbol=symbol,
                   instrument_id=saved_asset.get('id'),
                   asset_name=snapshot['asset']['name'], channel=channel,
                   created_at=datetime.now(timezone.utc).isoformat(), status='delivered', forecast=saved_forecast)
    with connect() as connection:
        connection.execute('INSERT INTO deliveries VALUES (?, ?)', (receipt['id'], json.dumps(receipt, ensure_ascii=False)))
    return receipt


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, value):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        try:
            self.get_response()
        except (MarketUnavailable, CatalogUnavailable) as error:
            self.log_error('%s: %s', error, error.__cause__)
            self.send_json(502, dict(error=str(error)))
        except KeyError:
            self.send_json(404, dict(error='未找到该标的，请从搜索结果中选择。'))
        except ValueError as error:
            self.send_json(400, dict(error=str(error)))

    def get_response(self):
        path = urlparse(self.path).path.rstrip('/')
        if path == '/health':
            return self.send_json(200, dict(status='ok', mode=PROVIDER.mode, market_source='akshare' if PROVIDER.mode == 'live' else 'mock', forecast_source='mock'))
        if path == '/v1/assets':
            return self.send_json(200, PROVIDER.assets())
        if path == '/v1/instruments':
            parameters = parse_qs(urlparse(self.path).query)
            query = parameters.get('q', [''])[0].strip()
            kind = parameters.get('kind', [None])[0]
            limit = int(parameters.get('limit', ['50'])[0])
            offset = int(parameters.get('offset', ['0'])[0])
            if len(query) > 80 or not 1 <= limit <= 100 or not 0 <= offset <= 100000:
                raise ValueError('Invalid search parameters')
            return self.send_json(200, PROVIDER.search(query, kind, limit, offset))
        if path.startswith('/v1/markets/'):
            symbol = unquote(path.rsplit('/', 1)[-1])
            return self.send_json(200, save_snapshot(PROVIDER.snapshot(symbol)))
        if path == '/v1/deliveries':
            with connect() as connection:
                rows = connection.execute('SELECT receipt FROM deliveries ORDER BY rowid DESC').fetchall()
            return self.send_json(200, [json.loads(row[0]) for row in rows])
        return self.send_json(404, dict(error='Not found'))

    def do_POST(self):
        if urlparse(self.path).path.rstrip('/') != '/v1/deliveries':
            return self.send_json(404, dict(error='Not found'))
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 16384:
                return self.send_json(413, dict(error='Body must be 1–16384 bytes'))
            body = json.loads(self.rfile.read(size))
            return self.send_json(201, make_delivery(body))
        except (ValueError, TypeError) as error:
            return self.send_json(400, dict(error=str(error)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8787)
    parser.add_argument('--host', default='0.0.0.0')
    parser.add_argument('--mode', choices=['live', 'demo'], default='live')
    args = parser.parse_args()
    fixtures = payload()
    catalog = InstrumentCatalog([instrument(asset['symbol'], asset['name'], asset['kind']) for asset in fixtures['assets']],
                                cache_dir=Path(__file__).with_name('runtime') / 'catalog')
    PROVIDER = MarketProvider(fixtures, mode=args.mode, catalog=catalog)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f'Market API: http://{args.host}:{args.port} · {args.mode} market data · mock forecasts', flush=True)
    server.serve_forever()
