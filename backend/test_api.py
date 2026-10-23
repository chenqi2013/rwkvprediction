import json
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from http.server import ThreadingHTTPServer
from unittest.mock import Mock, patch
from urllib.parse import urlencode
import server
from instrument_catalog import InstrumentCatalog
from test_instrument_search import catalog_loader
from test_live_data import daily_bars


class APIContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        server.DB = Path(cls.directory.name) / 'test.sqlite3'
        cls.original_provider = server.PROVIDER
        server.PROVIDER = server.MarketProvider(server.payload(), mode='demo')
        cls.http = ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        cls.base = f'http://127.0.0.1:{cls.http.server_port}'
        cls.thread = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()
        cls.directory.cleanup()
        server.PROVIDER = cls.original_provider

    def request(self, path, body=None):
        req = Request(self.base + path, data=json.dumps(body).encode() if body is not None else None,
                      headers={'Content-Type': 'application/json'})
        with urlopen(req) as response:
            return response.status, json.load(response)

    def test_quantile_and_time_contract(self):
        _, assets = self.request('/v1/assets')
        self.assertEqual(len(assets), 5)
        for asset in assets:
            _, snapshot = self.request('/v1/markets/' + asset['symbol'])
            self.assertEqual(snapshot['source'], 'mock')
            self.assertEqual(snapshot['history'][-1]['close'], asset['price'])
            self.assertEqual(snapshot['history'][-1]['date'], '2026-10-22')
            for days in (5, 20, 60):
                forecast = snapshot['predictions'][str(days)]
                self.assertEqual(len(forecast['points']), days)
                dates = [p['date'] for p in forecast['points']]
                self.assertEqual(dates, sorted(set(dates)))
                self.assertGreater(dates[0], snapshot['history'][-1]['date'])
                for point in forecast['points']:
                    values = [point[k] for k in ('p025', 'p10', 'p25', 'p50', 'p75', 'p90', 'p975')]
                    self.assertEqual(values, sorted(values))
                    self.assertGreater(values[0], 0)
                self.assertAlmostEqual(sum(s['probability'] for s in forecast['scenarios']), 1)

    def test_delivery_persists_and_rejects_mismatches(self):
        body = dict(symbol='510300', prediction_id='demo-510300-20-20261022', channel='in_app', confidence=95)
        status, receipt = self.request('/v1/deliveries', body)
        self.assertEqual(status, 201)
        self.assertEqual(receipt['forecast']['confidence'], 95)
        self.assertEqual(receipt['forecast']['lower'], 3.9174)
        self.assertEqual(receipt['forecast']['horizon'], 20)
        _, records = self.request('/v1/deliveries')
        self.assertTrue(any(record['id'] == receipt['id'] for record in records))
        for invalid in (dict(body, symbol='000300'), dict(body, channel='email'), dict(body, prediction_id='missing'), dict(body, confidence=99), []):
            with self.assertRaises(HTTPError) as error:
                self.request('/v1/deliveries', invalid)
            self.assertEqual(error.exception.code, 400)
            error.exception.close()
        _, records_after = self.request('/v1/deliveries')
        self.assertEqual(len(records), len(records_after))

    def test_unknown_market_returns_404(self):
        with self.assertRaises(HTTPError) as error:
            self.request('/v1/markets/UNKNOWN')
        self.assertEqual(error.exception.code, 404)
        error.exception.close()

    def test_search_and_non_default_stock_history(self):
        catalog = InstrumentCatalog([], loader=catalog_loader)
        provider = server.MarketProvider(server.payload(), catalog=catalog, history_loader=lambda symbol, kind: daily_bars())
        with patch.object(server, 'PROVIDER', provider):
            _, result = self.request('/v1/instruments?' + urlencode(dict(q='茅台', kind='股票')))
            self.assertEqual(result['total'], 1)
            self.assertNotIn('price', result['items'][0])
            _, snapshot = self.request('/v1/markets/' + result['items'][0]['id'])
            self.assertEqual(snapshot['asset']['name'], '贵州茅台')
            self.assertEqual(snapshot['source'], 'akshare')
            self.assertEqual(len(snapshot['history']), 61)
            for parameters in (dict(kind='crypto'), dict(limit=101), dict(offset=-1)):
                with self.assertRaises(HTTPError) as error:
                    self.request('/v1/instruments?' + urlencode(parameters))
                self.assertEqual(error.exception.code, 400)
                error.exception.close()

    def test_upstream_failure_returns_502_without_fake_quotes(self):
        provider = server.MarketProvider(server.payload(), history_loader=Mock(side_effect=ConnectionError('offline')))
        with patch.object(server, 'PROVIDER', provider):
            with self.assertRaises(HTTPError) as error:
                self.request('/v1/markets/510300')
            self.assertEqual(error.exception.code, 502)
            self.assertIn('未使用模拟行情替代', json.load(error.exception)['error'])
            error.exception.close()


if __name__ == '__main__':
    unittest.main()
