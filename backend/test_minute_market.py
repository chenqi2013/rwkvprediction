import copy
import json
import math
import threading
import unittest
from datetime import datetime, timedelta
from http.server import ThreadingHTTPServer
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import urlopen

import server
from akshare_adapter import SHANGHAI
from instrument_catalog import InstrumentCatalog, instrument
from market_provider import MarketUnavailable
from minute_market import MinuteMarket, aggregate_market, bar_returns, input_status, load_minutes, normalize


NOW = datetime(2026, 11, 9, 10, 40, 45, tzinfo=SHANGHAI)
STOCK = instrument('600519', '贵州茅台', '股票')
UNIVERSE = dict(id='test-fixed', instruments=[dict(symbol='600519', name='贵州茅台'), dict(symbol='000001', name='平安银行')])


def records(start='2026-11-09T09:31', count=75, price=10):
    origin = datetime.fromisoformat(start)
    return [dict(timestamp=(origin + timedelta(minutes=i)).isoformat(timespec='minutes'),
                 open=price, high=price + .2, low=price - .2, close=price,
                 volume=12, amount=12000) for i in range(count)]


def fixture(metadata=None, now=NOW):
    return normalize(records(), 'sina', now)


class MinuteTests(unittest.TestCase):
    def test_only_completed_minutes_and_explicit_volume_units(self):
        rows = records(count=75)
        data = normalize(rows, 'sina', NOW)
        self.assertEqual(data['bars'][-1]['timestamp'], '2026-11-09T10:39')
        self.assertEqual(data['bars'][0]['volume'], 12)
        self.assertEqual(normalize(rows, 'eastmoney', NOW)['bars'][0]['volume'], 1200)
        rows[0]['open'] = 0
        self.assertIsNone(normalize(rows, 'eastmoney', NOW)['bars'][0]['open'])
        with self.assertRaises(ValueError):
            normalize(rows, 'sina', NOW)

    def test_conflicting_duplicates_and_invalid_prices_rejected(self):
        rows = records()
        rows.append(dict(rows[0], close=10.1))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            normalize(rows, 'sina', NOW)
        rows = records()
        rows[0]['volume'] = float('nan')
        with self.assertRaises(ValueError):
            normalize(rows, 'sina', NOW)

    def test_gap_and_lunch_reset_returns_and_feature_prefix(self):
        morning = normalize(records(count=69), 'sina', NOW)['bars']
        del morning[5]
        returns = bar_returns(morning)
        self.assertNotIn(morning[0]['timestamp'], returns)
        self.assertNotIn(morning[5]['timestamp'], returns)
        state = input_status(morning)
        self.assertFalse(state['full_session_prefix'])
        afternoon = normalize(records(start='2026-11-09T13:01', count=4), 'sina', NOW.replace(hour=14))['bars']
        self.assertNotIn(afternoon[0]['timestamp'], bar_returns(morning + afternoon))

    def test_same_minute_equal_weight_market_stats_without_fill(self):
        target = fixture()['bars'][:3]
        one = copy.deepcopy(target)
        two = copy.deepcopy(target)
        one[1]['close'] = 10 * math.exp(.01)
        two[1]['close'] = 10 * math.exp(-.01)
        # Missing third minute for second stock must reduce count, not forward fill.
        two.pop()
        points = aggregate_market(target, {'a': {'bars': one}, 'b': {'bars': two}})
        self.assertEqual(points[0]['count'], 0)
        self.assertAlmostEqual(points[1]['market_return'], 0)
        self.assertAlmostEqual(points[1]['market_volatility'], 1)
        self.assertEqual(points[1]['market_up_fraction'], .5)
        self.assertEqual(points[2]['count'], 1)

    def test_historical_origin_has_no_future_values_and_universe_is_fixed(self):
        loader = Mock(side_effect=fixture)
        provider = MinuteMarket(loader=loader, now=lambda: NOW, universe=UNIVERSE)
        snapshot = provider.snapshot(STOCK, day='2026-11-09', at='10:35', include_market=True)
        self.assertEqual(snapshot['as_of'], '2026-11-09T10:35:00+08:00')
        self.assertEqual(snapshot['rwkv_input']['status'], 'available')
        self.assertEqual(snapshot['market_statistics']['size'], 2)
        self.assertFalse(snapshot['market_statistics']['training_universe_match'])
        self.assertEqual(snapshot['market_statistics']['points'][-1]['count'], 2)
        self.assertEqual(loader.call_count, 2, 'target reuses the same per-identity cache')
        self.assertNotIn('predictions', snapshot)
        later = provider.snapshot(STOCK, day='2026-11-09', at='10:36', include_market=True)
        self.assertEqual(snapshot['market_statistics']['points'], later['market_statistics']['points'][:-1])

    def test_failures_and_missing_statistics_never_become_ready(self):
        def loader(metadata, now):
            if metadata['id'] != STOCK['id']:
                raise ConnectionError('offline')
            return fixture()
        provider = MinuteMarket(loader=loader, now=lambda: NOW, universe=UNIVERSE)
        result = provider.snapshot(STOCK, include_market=True)
        self.assertEqual(result['market_statistics']['failed_instruments'], ['sz-stock-000001'])
        self.assertEqual(result['market_statistics']['loaded_count'], 1)
        self.assertTrue(result['warnings'])
        self.assertIn('尚未加载同期市场统计', provider.snapshot(STOCK)['rwkv_input']['reasons'])
        with self.assertRaises(MarketUnavailable):
            MinuteMarket(loader=Mock(side_effect=ConnectionError()), now=lambda: NOW).snapshot(STOCK)

    def test_date_validation_and_after_close_input_rejection(self):
        provider = MinuteMarket(loader=fixture, now=lambda: NOW)
        for day, at in [('2026-11-10', None), ('20261109', None), (None, '10:35'), ('2026-11-09', '99:00')]:
            with self.assertRaises(ValueError):
                provider.snapshot(STOCK, day=day, at=at)
        closing = normalize(records(start='2026-11-09T13:01', count=120), 'sina', NOW.replace(hour=16))['bars']
        self.assertIn('未来 30 分钟超出当前连续交易时段', input_status(closing)['reasons'])

    def test_sina_adapter_preserves_exchange_identity_and_has_timeout(self):
        response = Mock(text='/*jsonp*/\n=(' + json.dumps([dict(row, day=row['timestamp']) for row in records()]) + ');')
        with patch('requests.get', return_value=response) as get:
            load_minutes(instrument('000001', '上证指数', '指数'), NOW)
            self.assertEqual(get.call_args.kwargs['params']['symbol'], 'sh000001')
            self.assertEqual(get.call_args.kwargs['timeout'], (5, 12))
        with patch('requests.get', side_effect=ConnectionError()), patch('akshare.stock_zh_a_hist_min_em') as fallback:
            with self.assertRaises(ConnectionError):
                load_minutes(instrument('000001', '上证指数', '指数'), NOW)
            fallback.assert_not_called()


class MinuteAPITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        cls.base = f'http://127.0.0.1:{cls.http.server_port}'
        threading.Thread(target=cls.http.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()

    def test_route_prepares_data_without_inference(self):
        engine = Mock()
        provider = server.MarketProvider(server.payload(), catalog=InstrumentCatalog([STOCK]), forecast_engine=engine)
        with patch.object(server, 'PROVIDER', provider), patch.object(server, 'MINUTES', MinuteMarket(loader=fixture, now=lambda: NOW, universe=UNIVERSE)), patch.object(server, 'save_snapshot') as save:
            with urlopen(self.base + '/v1/minute-markets/sh-stock-600519?date=2026-11-09&at=10:35&include_market=1') as response:
                result = json.load(response)
                self.assertEqual(result['granularity'], '1m')
                self.assertEqual(result['rwkv_input']['status'], 'available')
            engine.generate.assert_not_called()
            save.assert_not_called()
            for query in ('include_market=yes', 'date=2030-01-01', 'inference=server', 'include_market=0&include_market=1'):
                with self.assertRaises(HTTPError) as error:
                    urlopen(self.base + '/v1/minute-markets/sh-stock-600519?' + query)
                self.assertEqual(error.exception.code, 400)
                error.exception.close()

    def test_demo_and_upstream_error_are_explicit(self):
        for provider, minutes, status in [
            (server.MarketProvider(server.payload(), mode='demo'), MinuteMarket(), 400),
            (server.MarketProvider(server.payload()), MinuteMarket(loader=Mock(side_effect=ConnectionError())), 502),
        ]:
            with patch.object(server, 'PROVIDER', provider), patch.object(server, 'MINUTES', minutes):
                with self.assertRaises(HTTPError) as error:
                    urlopen(self.base + '/v1/minute-markets/510300')
                self.assertEqual(error.exception.code, status)
                error.exception.close()


if __name__ == '__main__':
    unittest.main()
