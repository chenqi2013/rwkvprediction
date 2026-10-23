import copy
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

import akshare_adapter
import server
from market_provider import MarketProvider, MarketUnavailable


def daily_bars():
    start = datetime(2026, 7, 1)
    return [dict(date=(start + timedelta(days=offset)).date().isoformat(), open=3.9,
                 close=4 + offset / 1000, high=4.5, low=3.8, volume=200000, amount=80000000)
            for offset in range(61)]


class LiveDataTests(unittest.TestCase):
    def test_sina_fallback_preserves_real_etf_prices(self):
        bars = daily_bars()
        frame = unittest.mock.Mock()
        frame.to_dict.return_value = bars
        now = datetime(2026, 10, 23, 16, tzinfo=akshare_adapter.SHANGHAI)
        with patch('akshare.fund_etf_hist_em', side_effect=ConnectionError('disconnected')), patch('akshare.fund_etf_hist_sina', return_value=frame) as fallback:
            result = akshare_adapter.history('159915', 'ETF', now=now)
        fallback.assert_called_once_with(symbol='sz159915')
        self.assertEqual(result[-1]['close'], bars[-1]['close'])
        self.assertEqual(result[-1]['amount'], bars[-1]['amount'])
        self.assertEqual(result[-1]['data_vendor'], 'sina')

    def test_sina_index_missing_amount_is_explicit(self):
        bars = daily_bars()
        for bar in bars:
            del bar['amount']
        frame = unittest.mock.Mock()
        frame.to_dict.return_value = bars
        now = datetime(2026, 10, 23, 16, tzinfo=akshare_adapter.SHANGHAI)
        with patch('akshare.stock_zh_index_daily_em', side_effect=ConnectionError('disconnected')), patch('akshare.stock_zh_index_daily', return_value=frame) as fallback:
            result = akshare_adapter.history('000300', '指数', now=now)
        fallback.assert_called_once_with(symbol='sh000300')
        provider = MarketProvider(server.payload(), history_loader=lambda symbol, kind: result)
        snapshot = provider.snapshot('000300')
        self.assertEqual(snapshot['asset']['volume'], '--')
        self.assertEqual(snapshot['market_vendor'], 'sina')
        self.assertEqual(snapshot['asset']['price'], bars[-1]['close'])

    def test_both_vendors_unavailable_returns_error(self):
        with patch('akshare.fund_etf_hist_em', side_effect=ConnectionError('eastmoney offline')), patch('akshare.fund_etf_hist_sina', side_effect=ConnectionError('sina offline')), patch('market_provider.time.sleep'):
            provider = MarketProvider(server.payload())
            with self.assertRaises(MarketUnavailable):
                provider.snapshot('510300')
        self.assertEqual(provider.cache, {})

    def test_real_fields_and_mock_predictions_share_price_and_date(self):
        fixtures = server.payload()
        original = copy.deepcopy(fixtures)
        bars = daily_bars()
        loader = unittest.mock.Mock(return_value=bars)
        provider = MarketProvider(fixtures, history_loader=loader)
        for symbol in ('510300', '000300'):
            snapshot = provider.snapshot(symbol)
            self.assertEqual(snapshot['source'], 'akshare')
            self.assertEqual(snapshot['history'][-1]['close'], bars[-1]['close'])
            self.assertEqual(snapshot['asset']['previous_close'], bars[-2]['close'])
            self.assertEqual(snapshot['asset']['open'], bars[-1]['open'])
            self.assertEqual(snapshot['asset']['volume'], '8,000.00万')
            for horizon, forecast in snapshot['predictions'].items():
                self.assertTrue(forecast['id'].startswith('mock-akshare-'))
                self.assertIn('尚未调用 RWKV', forecast['explanation'])
                self.assertEqual(len(forecast['points']), int(horizon))
                self.assertGreater(forecast['points'][0]['date'], bars[-1]['date'])
                for point in forecast['points']:
                    quantiles = [point[key] for key in ('p025', 'p10', 'p25', 'p50', 'p75', 'p90', 'p975')]
                    self.assertEqual(quantiles, sorted(quantiles))
            self.assertIs(provider.snapshot(symbol), snapshot)
        self.assertEqual(loader.call_count, 2)
        self.assertEqual(fixtures, original)

    def test_intraday_bar_and_invalid_price_are_rejected(self):
        bars = daily_bars()
        today = datetime.fromisoformat(bars[-1]['date'] + 'T14:00:00').replace(tzinfo=akshare_adapter.SHANGHAI)
        previous_day = dict(bars[0], date=(datetime.fromisoformat(bars[0]['date']) - timedelta(days=1)).date().isoformat())
        result = akshare_adapter.normalize([previous_day] + bars, today)
        self.assertEqual(result[-1]['date'], bars[-2]['date'])
        self.assertEqual(len(result), 61)
        today = today.replace(hour=16)
        self.assertEqual(akshare_adapter.normalize(bars[::-1], today), bars)
        for invalid in (float('nan'), float('inf'), 0, -1):
            broken = copy.deepcopy(bars)
            broken[-1]['close'] = invalid
            with self.assertRaises(ValueError):
                akshare_adapter.normalize(broken, today)

    def test_upstream_failure_has_no_mock_fallback(self):
        loader = unittest.mock.Mock(side_effect=ConnectionError('upstream offline'))
        provider = MarketProvider(server.payload(), history_loader=loader)
        with self.assertRaises(MarketUnavailable):
            provider.snapshot('510300')
        self.assertEqual(provider.cache, {})

    def test_transient_upstream_disconnect_is_retried(self):
        loader = unittest.mock.Mock(side_effect=[ConnectionError('connection closed'), daily_bars()])
        provider = MarketProvider(server.payload(), history_loader=loader)
        with patch('market_provider.time.sleep'):
            snapshot = provider.snapshot('510300')
        self.assertEqual(snapshot['source'], 'akshare')
        self.assertEqual(loader.call_count, 2)
        self.assertEqual(snapshot['asset']['price'], daily_bars()[-1]['close'])

    def test_delivery_retains_issued_forecast_after_market_changes(self):
        bars = daily_bars()
        provider = MarketProvider(server.payload(), history_loader=lambda symbol, kind: bars, ttl=0)
        with tempfile.TemporaryDirectory() as directory, patch.object(server, 'DB', Path(directory) / 'test.sqlite3'), patch.object(server, 'PROVIDER', provider):
            first = server.save_snapshot(provider.snapshot('510300'))
            prediction = first['predictions']['20']
            bars[-1]['close'] = 4.2
            second = server.save_snapshot(provider.snapshot('510300'))
            self.assertNotEqual(prediction['id'], second['predictions']['20']['id'])
            receipt = server.make_delivery(dict(symbol='510300', prediction_id=prediction['id'], confidence=95, channel='in_app'))
            self.assertEqual(receipt['forecast']['median'], prediction['points'][-1]['p50'])
            self.assertEqual(receipt['forecast']['market_source'], 'akshare')
            self.assertEqual(receipt['forecast']['as_of'], first['as_of'])
            with self.assertRaises(ValueError):
                server.make_delivery(dict(symbol='000300', prediction_id=prediction['id'], channel='in_app'))


if __name__ == '__main__':
    unittest.main()
