"""Local demonstration API. Uses only Python's standard library.

Run: python3 backend/server.py --port 8787
Forecasts are synthetic. No external notification is sent by delivery endpoints.
"""
import argparse
import json
import sqlite3
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'rwkvprediction/rwkvprediction/Resources/market-demo.json'
DB = Path(__file__).with_name('deliveries.sqlite3')


def payload():
    return json.loads(FIXTURES.read_text())


def connect():
    connection = sqlite3.connect(DB)
    connection.execute('CREATE TABLE IF NOT EXISTS deliveries (id TEXT PRIMARY KEY, receipt TEXT NOT NULL)')
    return connection


def make_delivery(body):
    if not isinstance(body, dict):
        raise ValueError('JSON object required')
    symbol = body.get('symbol')
    channel = body.get('channel')
    prediction_id = body.get('prediction_id')
    confidence = body.get('confidence', 80)
    if type(confidence) is not int or confidence not in (80, 95):
        raise ValueError('confidence must be 80 or 95')
    if not isinstance(symbol, str) or symbol not in payload()['snapshots']:
        raise ValueError('Unknown symbol')
    snapshot = payload()['snapshots'][symbol]
    if prediction_id not in [f['id'] for f in snapshot['predictions'].values()]:
        raise ValueError('Prediction does not belong to this symbol')
    if channel not in ('in_app', 'webhook_demo'):
        raise ValueError('channel must be in_app or webhook_demo')
    forecast = next(f for f in snapshot['predictions'].values() if f['id'] == prediction_id)
    end = forecast['points'][-1]
    saved_forecast = dict(horizon=forecast['horizon'], confidence=confidence,
                          lower=end['p025' if confidence == 95 else 'p10'], median=end['p50'],
                          upper=end['p975' if confidence == 95 else 'p90'], currency='CNY',
                          decimals=3 if snapshot['asset']['kind'] == 'ETF' else 2, explanation=forecast['explanation'])
    receipt = dict(id=str(uuid.uuid4()), prediction_id=prediction_id, symbol=symbol,
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
        path = urlparse(self.path).path.rstrip('/')
        if path == '/health':
            return self.send_json(200, dict(status='ok', mode='mock'))
        if path == '/v1/assets':
            return self.send_json(200, payload()['assets'])
        if path.startswith('/v1/markets/'):
            symbol = path.rsplit('/', 1)[-1]
            result = payload()['snapshots'].get(symbol)
            return self.send_json(200, result) if result else self.send_json(404, dict(error='Unknown symbol'))
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
    parser.add_argument('--host', default='127.0.0.1')
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f'Demo API: http://{args.host}:{args.port} · synthetic data only', flush=True)
    server.serve_forever()
