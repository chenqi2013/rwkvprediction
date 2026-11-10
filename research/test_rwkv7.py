import csv
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

from rwkv7_cpu import wkv_recurrence
from rwkv7_features import market_statistics, prepare_features
from rwkv7_predict import decode, read_input


def fixture(start='2026-11-06T09:30', length=65):
    times = np.datetime64(start, 'm') + np.arange(length).astype('timedelta64[m]')
    bars = np.tile([10, 10.1, 9.9, 10, 1000], (length, 1))
    market = np.tile([0, 0.1, 0.5], (length, 1)).astype(np.float32)
    return bars, times, market


def write_csv(path, bars, times, market):
    with path.open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['timestamp', 'open', 'high', 'low', 'close', 'volume',
                         'market_return', 'market_volatility', 'market_up_fraction'])
        for stamp, bar, stat in zip(times, bars, market):
            writer.writerow([str(stamp), *bar, *stat])


class RWKV7Tests(unittest.TestCase):
    def test_minute_api_json_matches_csv_and_rejects_unavailable_input(self):
        bars, times, market = fixture()
        document = {
            'granularity': '1m', 'timezone': 'Asia/Shanghai', 'volume_unit': 'share',
            'source': 'sina', 'price_adjustment': 'none',
            'instrument': {'kind': '股票', 'market': 'sh'},
            'rwkv_input': {'status': 'available', 'session_start': str(times[0])},
            'bars': [{'timestamp': str(stamp), **dict(zip(('open', 'high', 'low', 'close', 'volume'), bar.tolist()))}
                     for stamp, bar in zip(times, bars)],
            'market_statistics': {'points': [
                dict(timestamp=str(stamp), market_return=float(stat[0]), market_volatility=float(stat[1]), market_up_fraction=float(stat[2]))
                for stamp, stat in zip(times, market)
            ]},
        }
        # The session's first raw anchor may have no cross-sectional return.
        document['market_statistics']['points'][0]['market_return'] = None
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'input.json'
            path.write_text(json.dumps(document))
            values = read_input(path)
            np.testing.assert_array_equal(values[0], prepare_features(bars, times, market)[0])
            envelope = {'response': {'body': document}}
            path.write_text(json.dumps(envelope))
            np.testing.assert_array_equal(read_input(path)[0], values[0])
            document['rwkv_input'].update(status='unavailable', reasons=['缺失市场统计'])
            path.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, 'unavailable'):
                read_input(path)

    def test_constant_price_features_and_market_contract(self):
        features, anchor = prepare_features(*fixture())
        self.assertEqual(features.shape, (64, 23))
        self.assertEqual(anchor, 10)
        np.testing.assert_array_equal(features[:, [0, 1, *range(10, 18), 19]], 0)
        np.testing.assert_allclose(features[:, 4], np.log1p(1000) / 10)
        np.testing.assert_allclose(features[:, 20:], np.tile([0, 0.1, 0.5], (64, 1)))

    def test_market_statistics_ignore_missing_bars_and_use_population_std(self):
        values = np.array([[1., -1., np.nan], [2., 0., 4.]])
        result = market_statistics(values)
        np.testing.assert_allclose(result, [[0, 1, .5], [2, np.sqrt(8 / 3), 2 / 3]], rtol=1e-6)
        with self.assertRaises(ValueError):
            market_statistics(np.array([[np.nan, np.nan]]))

    def test_gaps_lunch_and_nonfinite_market_are_rejected(self):
        bars, times, market = fixture()
        times[20:] += np.timedelta64(1, 'm')
        with self.assertRaises(ValueError):
            prepare_features(bars, times, market)
        bars, times, market = fixture('2026-11-06T11:00')
        with self.assertRaises(ValueError):
            prepare_features(bars, times, market)
        bars, times, market = fixture()
        market[-1, 0] = np.nan
        with self.assertRaises(ValueError):
            prepare_features(bars, times, market)

    def test_raw_csv_requires_prefix_and_no_future_session_crossing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'input.csv'
            write_csv(path, *fixture())
            self.assertEqual(str(read_input(path)[2]), '2026-11-06T10:34')
            # A valid 65-bar slice is insufficient: earlier rolling context was lost.
            write_csv(path, *fixture('2026-11-06T09:35'))
            with self.assertRaisesRegex(ValueError, 'prefix'):
                read_input(path)
            write_csv(path, *fixture(length=100))
            with self.assertRaisesRegex(ValueError, '30-minute'):
                read_input(path)

    def test_scalar_recurrence_matches_hand_calculation_and_resets(self):
        # D=H=B=1: first state=2*3=6; second=(decay+0.2*0.5)*6+4*5.
        def tensor(values):
            return torch.tensor(values, dtype=torch.float32).reshape(1, 2, 1, 1)
        args = [tensor(x) for x in ([1, 2], [0, 0], [2, 4], [3, 5], [0, .5], [0, .2])]
        result = wkv_recurrence(*args)
        decay = np.exp(-np.exp(-.5) * .5)
        np.testing.assert_allclose(result.flatten(), [6, 2 * ((decay + .1) * 6 + 20)], rtol=1e-6)
        torch.testing.assert_close(wkv_recurrence(*args), result, rtol=0, atol=0)
        batch = [x.repeat(2, 1, 1, 1) for x in args]
        torch.testing.assert_close(wkv_recurrence(*batch), result.repeat(2, 1, 1, 1))

    def test_matrix_recurrence_has_key_value_orientation(self):
        def t(values):
            return torch.tensor(values, dtype=torch.float32).reshape(1, 1, 1, 2)
        r, logits, k, v, a, b = [t(x) for x in ([1, 2], [0, 0], [3, 4], [5, 6], [0, 0], [0, 0])]
        # Zero initial state; output=(r dot k)*v, with no transposition or lag.
        torch.testing.assert_close(wkv_recurrence(r, logits, k, v, a, b).flatten(), torch.tensor([55., 66.]))

    def test_quantiles_are_sorted_and_decoded_from_one_anchor(self):
        raw = np.tile(np.arange(9, 0, -1, dtype=np.float32), (30, 1))
        points = decode(raw, 10, np.datetime64('2026-11-06T10:34'))
        self.assertEqual(points[-1]['timestamp'], '2026-11-06T11:04')
        self.assertAlmostEqual(points[0]['median_price'], 10 * np.exp(.05))
        self.assertEqual(points[0]['price_quantiles'], points[-1]['price_quantiles'])
        np.testing.assert_allclose(points[0]['interval_80'], 10 * np.exp(np.array([.01, .09])))
        self.assertEqual(points[0]['raw_cumulative_log_return_x100'], raw[0].tolist())
        with self.assertRaises(ValueError):
            decode(np.full((30, 9), np.nan), 10)


if __name__ == '__main__':
    unittest.main()
