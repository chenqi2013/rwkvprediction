import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from unittest.mock import Mock, patch

import akshare_adapter
import server
from instrument_catalog import CatalogUnavailable, InstrumentCatalog, instrument
from market_provider import MarketProvider
from test_live_data import daily_bars


def catalog_loader(kind):
    return {
        'ETF': [instrument('sh510050', '上证50ETF', 'ETF')],
        '指数': [instrument('000001', '上证指数', '指数'), instrument('399006', '创业板指', '指数')],
        '股票': [instrument('000001', '平安银行', '股票'), instrument('600519', '贵州茅台', '股票')],
    }[kind]


class InstrumentSearchTests(unittest.TestCase):
    def test_search_names_codes_pagination_and_colliding_codes(self):
        catalog = InstrumentCatalog([], loader=catalog_loader)
        matches = catalog.search('000001')
        self.assertEqual({item['id'] for item in matches['items']}, {'sh-index-000001', 'sz-stock-000001'})
        self.assertEqual(catalog.search('茅台')['items'][0]['id'], 'sh-stock-600519')
        self.assertEqual(catalog.search('sz000001', '股票')['items'][0]['name'], '平安银行')
        self.assertEqual(catalog.search('000001', '指数')['total'], 1)
        first = catalog.search('', limit=2)
        second = catalog.search('', limit=2, offset=2)
        self.assertTrue(first['has_more'])
        self.assertFalse({item['id'] for item in first['items']} & {item['id'] for item in second['items']})
        self.assertEqual(first['total'], 5)
        self.assertEqual(catalog.resolve('sz-stock-000001')['name'], '平安银行')
        with self.assertRaises(KeyError):
            catalog.resolve('sh-stock-000001')

    def test_catalog_persists_metadata_and_reuses_fresh_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            catalog = InstrumentCatalog([], loader=catalog_loader, cache_dir=directory)
            self.assertEqual(catalog.search('茅台')['total'], 1)
            loader = Mock(side_effect=ConnectionError('offline'))
            restored = InstrumentCatalog([], loader=loader, cache_dir=directory)
            self.assertEqual(restored.search('茅台')['items'][0]['symbol'], '600519')
            loader.assert_not_called()

    def test_failed_catalog_is_an_error_partial_and_stale_lists_have_warnings(self):
        def loader(kind):
            if kind == '股票':
                raise ConnectionError('offline')
            return catalog_loader(kind)

        catalog = InstrumentCatalog([], loader=loader)
        partial = catalog.search('茅台')
        self.assertEqual(partial['items'], [])
        self.assertTrue(any('股票' in warning for warning in partial['warnings']))
        with self.assertRaises(CatalogUnavailable):
            catalog.search('茅台', '股票')
        with tempfile.TemporaryDirectory() as directory:
            InstrumentCatalog([], loader=catalog_loader, cache_dir=directory).search('')
            stale = InstrumentCatalog([], loader=Mock(side_effect=ConnectionError('offline')), cache_dir=directory, ttl=0)
            result = stale.search('茅台', '股票')
            self.assertEqual(result['items'][0]['name'], '贵州茅台')
            self.assertTrue(result['warnings'])

    def test_dynamic_stock_and_index_snapshots_and_delivery_keep_identity(self):
        catalog = InstrumentCatalog([], loader=catalog_loader)
        catalog.search('')
        provider = MarketProvider(server.payload(), catalog=catalog, history_loader=lambda symbol, kind: daily_bars())
        stock = provider.snapshot('sz-stock-000001')
        index = provider.snapshot('sh-index-000001')
        self.assertEqual(stock['asset']['name'], '平安银行')
        self.assertEqual(index['asset']['name'], '上证指数')
        self.assertEqual(stock['asset']['kind'], '股票')
        self.assertEqual(stock['history'], index['history'])
        self.assertNotEqual(stock['predictions']['20']['id'], index['predictions']['20']['id'])
        self.assertEqual(provider.snapshot('000001')['asset']['id'], 'sh-index-000001')
        with tempfile.TemporaryDirectory() as directory, patch.object(server, 'DB', Path(directory) / 'test.sqlite3'), patch.object(server, 'PROVIDER', provider):
            server.save_snapshot(stock)
            body = dict(symbol='000001', instrument_id='sz-stock-000001', prediction_id=stock['predictions']['20']['id'], confidence=80, channel='in_app')
            receipt = server.make_delivery(body)
            self.assertEqual(receipt['asset_name'], '平安银行')
            self.assertEqual(receipt['instrument_id'], 'sz-stock-000001')
            for invalid in (dict(body, instrument_id='sh-index-000001'), dict(body, symbol='600519')):
                with self.assertRaises(ValueError):
                    server.make_delivery(invalid)

    def test_stock_and_shenzhen_index_use_correct_sina_history(self):
        frame = Mock()
        frame.to_dict.return_value = daily_bars()[-3:]
        now = datetime(2026, 10, 23, 16, tzinfo=akshare_adapter.SHANGHAI)
        with patch('akshare.stock_zh_a_hist', side_effect=ConnectionError('offline')), patch('akshare.stock_zh_a_daily', return_value=frame) as fallback:
            stock = akshare_adapter.history('sz000001', '股票', now=now)
        self.assertEqual(fallback.call_args.kwargs['symbol'], 'sz000001')
        self.assertEqual(len(stock), 3)
        self.assertEqual(stock[-1]['close'], daily_bars()[-1]['close'])
        with patch('akshare.stock_zh_index_daily_em', side_effect=ConnectionError('offline')), patch('akshare.stock_zh_index_daily', return_value=frame) as fallback:
            akshare_adapter.history('sz399006', '指数', now=now)
        fallback.assert_called_once_with(symbol='sz399006')
        with self.assertRaises(ValueError):
            akshare_adapter.normalize(daily_bars()[-1:], now)

    def test_sina_native_decoders_do_not_run_concurrently(self):
        first_entered = threading.Event()
        release = threading.Event()
        second_primary = threading.Event()
        second_entered = threading.Event()
        frame = Mock()
        frame.to_dict.return_value = daily_bars()

        def first_fallback(**kwargs):
            first_entered.set()
            if not release.wait(3):
                raise TimeoutError('test timed out')
            return frame

        def primary(**kwargs):
            second_primary.set()
            raise ConnectionError('offline')

        def second_fallback(**kwargs):
            second_entered.set()
            return frame

        now = datetime(2026, 10, 23, 16, tzinfo=akshare_adapter.SHANGHAI)
        with patch('akshare.stock_zh_a_hist', side_effect=ConnectionError('offline')), patch('akshare.stock_zh_a_daily', side_effect=first_fallback), patch('akshare.stock_zh_index_daily_em', side_effect=primary), patch('akshare.stock_zh_index_daily', side_effect=second_fallback):
            with ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(akshare_adapter.history, 'sh600519', '股票', now)
                self.assertTrue(first_entered.wait(3))
                second = pool.submit(akshare_adapter.history, 'sz399006', '指数', now)
                try:
                    self.assertTrue(second_primary.wait(3))
                    self.assertFalse(second_entered.wait(.05))
                finally:
                    release.set()
                self.assertEqual(len(first.result()), 61)
                self.assertEqual(len(second.result()), 61)


if __name__ == '__main__':
    unittest.main()
