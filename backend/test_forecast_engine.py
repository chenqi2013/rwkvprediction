import copy
import json
import math
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import urlopen

import server
from forecast_engine import ForecastUnavailable, OpenAICompatibleForecastEngine, configured_engine
from market_provider import MarketProvider
from test_live_data import daily_bars


class LocalForecastTests(unittest.TestCase):
    def setUp(self):
        self.content = {str(h): dict(return_pct=change, summary='未来走势可能随历史动量变化，需关注波动风险。')
                        for h, change in [(5, -1), (20, 2), (60, 4)]}
        self.requests = []
        self.finish_reason = 'stop'
        self.status = 200
        owner = self

        class ModelHandler(BaseHTTPRequestHandler):
            def do_POST(self):
                owner.requests.append((self.path, json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
                body = json.dumps(dict(choices=[dict(finish_reason=owner.finish_reason,
                                                    message=dict(content=json.dumps(owner.content)))],
                                       usage=dict(prompt_tokens=123, completion_tokens=45))).encode()
                self.send_response(owner.status)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.http = ThreadingHTTPServer(('127.0.0.1', 0), ModelHandler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.engine = OpenAICompatibleForecastEngine(f'http://127.0.0.1:{self.http.server_port}/v1')
        self.loader = Mock(return_value=daily_bars())
        self.provider = MarketProvider(server.payload(), forecast_engine=self.engine, history_loader=self.loader)

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()

    def test_real_adapter_contract_targets_quantiles_and_measured_usage(self):
        snapshot = self.provider.snapshot('510300')
        self.assertEqual(self.requests[0][0], '/v1/chat/completions')
        request = self.requests[0][1]
        self.assertFalse(request['stream'])
        self.assertEqual(request['model'], 'qwen2.5:0.5b')
        self.assertEqual(request['response_format']['type'], 'json_schema')
        self.assertIn('2026-08-30', request['messages'][1]['content'])
        self.assertEqual(snapshot['source'], 'akshare')
        self.assertEqual(snapshot['forecast_source'], 'local_model')
        self.assertEqual(snapshot['asset']['price'], daily_bars()[-1]['close'])
        for horizon in (5, 20, 60):
            forecast = snapshot['predictions'][str(horizon)]
            self.assertEqual(len(forecast['points']), horizon)
            dates = [p['date'] for p in forecast['points']]
            self.assertEqual(dates, sorted(set(dates)))
            self.assertGreater(dates[0], snapshot['history'][-1]['date'])
            for point in forecast['points']:
                values = [point[key] for key in ('p025', 'p10', 'p25', 'p50', 'p75', 'p90', 'p975')]
                self.assertEqual(values, sorted(values))
                self.assertTrue(all(math.isfinite(v) and v > 0 for v in values))
            target = snapshot['asset']['price'] * (1 + self.content[str(horizon)]['return_pct'] / 100)
            self.assertAlmostEqual(forecast['points'][-1]['p50'], target, places=5)
            self.assertEqual(forecast['backtest']['status'], 'not_evaluated')
            self.assertEqual(forecast['usage']['source'], 'measured')
            self.assertEqual(forecast['usage']['input_tokens'], 123)
            self.assertEqual(forecast['usage']['output_tokens'], 45)
        self.assertIs(self.provider.snapshot('510300'), snapshot)
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.loader.call_count, 1)
        self.provider.assets()
        self.assertEqual(len(self.requests), 1, 'quote-only endpoint must not run inference')

    def test_invalid_or_truncated_model_output_never_becomes_mock(self):
        original = copy.deepcopy(self.content)
        for invalid in (True, float('nan'), float('inf'), -51, 101, '2'):
            self.content['5']['return_pct'] = invalid
            with self.assertRaises(ForecastUnavailable):
                self.provider.snapshot('510300')
            self.assertFalse(self.provider.cache)
        self.content = original
        self.finish_reason = 'length'
        with self.assertRaises(ForecastUnavailable):
            self.provider.snapshot('510300')
        self.assertEqual(self.loader.call_count, 1, 'model failure must not refetch fresh market data')
        self.finish_reason = 'stop'
        self.status = 404
        with self.assertRaises(ForecastUnavailable):
            self.provider.snapshot('510300')
        self.status = 200
        self.assertEqual(self.provider.snapshot('510300')['forecast_source'], 'local_model')

    def test_api_failure_is_503_and_delivery_retains_model_provenance(self):
        api = ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        thread = threading.Thread(target=api.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory, patch.object(server, 'PROVIDER', self.provider), patch.object(server, 'DB', Path(directory) / 'test.sqlite3'):
                self.status = 500
                with self.assertRaises(HTTPError) as failure:
                    urlopen(f'http://127.0.0.1:{api.server_port}/v1/markets/510300')
                self.assertEqual(failure.exception.code, 503)
                self.assertIn('未使用模拟预测替代', json.load(failure.exception)['error'])
                failure.exception.close()
                self.status = 200
                first = server.save_snapshot(self.provider.snapshot('510300'))
                forecast = first['predictions']['20']
                self.provider.cache.clear()
                self.content['20']['return_pct'] = -3
                second = server.save_snapshot(self.provider.snapshot('510300'))
                self.assertNotEqual(forecast['id'], second['predictions']['20']['id'])
                receipt = server.make_delivery(dict(symbol='510300', prediction_id=forecast['id'], confidence=95, channel='in_app'))
                self.assertEqual(receipt['forecast']['forecast_source'], 'local_model')
                self.assertEqual(receipt['forecast']['model'], 'qwen2.5:0.5b')
                self.assertEqual(receipt['forecast']['median'], forecast['points'][-1]['p50'])
        finally:
            api.shutdown()
            api.server_close()
            thread.join()

    def test_config_replacement_and_demo_stays_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            config.write_text(json.dumps(dict(provider='openai_compatible', model='rwkv-local',
                                              base_url='http://127.0.0.1:8000/v1', structured_output=False)))
            engine = configured_engine(config)
            self.assertEqual(engine.model, 'rwkv-local')
            self.assertFalse(engine.structured_output)
        demo = MarketProvider(server.payload(), mode='demo', forecast_engine=self.engine)
        self.assertEqual(demo.snapshot('510300')['source'], 'mock')
        self.assertFalse(self.requests)


if __name__ == '__main__':
    unittest.main()
