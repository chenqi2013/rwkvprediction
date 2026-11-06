import copy
import math
import unittest
from datetime import date, timedelta

from evaluate import (HORIZONS, baseline, future_calendar, input_digest, metrics,
                      model_input, observation, qwen_quote, validate_model_dates, windows)
from chronos_runtime import ChronosRuntime, PAST_COVARIATES, chronos_task
from prepare_data import fingerprint, validate_bars


def fixture():
    day = date(2025, 1, 1)
    bars = []
    while len(bars) < 500:
        if day.weekday() < 5:
            price = 10 * math.exp(len(bars) * .001)
            bars.append(dict(date=day.isoformat(), open=price, high=price * 1.01,
                             low=price * .99, close=price, volume=1000, amount=price * 1000))
        day += timedelta(days=1)
    return dict(stocks=[dict(symbol='sh600519', name='样例', bars=bars)])


class EvaluationTests(unittest.TestCase):
    def test_windows_use_only_past_and_nonoverlapping_labels(self):
        data = fixture()
        cases = windows(data)
        self.assertEqual(len(cases), 3)
        for case in cases:
            self.assertEqual(len(case['history']), 61)
            self.assertEqual(len(case['future']), 60)
            self.assertLess(case['history'][-1]['date'], case['future'][0]['date'])
        for previous, current in zip(cases, cases[1:]):
            self.assertEqual(previous['future'][-1]['date'], current['history'][-1]['date'])
            self.assertLess(previous['future'][-1]['date'], current['future'][0]['date'])

    def test_future_prices_cannot_change_baselines_or_model_input(self):
        case = windows(fixture())[0]
        changed = copy.deepcopy(case)
        for row in changed['future']:
            row['close'] *= 20
        self.assertEqual(model_input(case), model_input(changed))
        self.assertNotIn('future', model_input(case))
        self.assertEqual(input_digest(case), input_digest(changed))
        self.assertEqual(qwen_quote(case), qwen_quote(changed))
        self.assertEqual(baseline(case, True), baseline(changed, True))
        self.assertNotIn('predictions', qwen_quote(case))

    def test_trend_and_exact_horizon_metrics_have_known_solution(self):
        cases = windows(fixture())
        records = [observation(case, name, baseline(case, trend))
                   for case in cases for name, trend in [('flat', False), ('trend', True)]]
        result = metrics(cases, records, ['flat', 'trend'])
        self.assertEqual(result['common_count'], 3)
        for horizon in HORIZONS:
            self.assertAlmostEqual(result['by_model']['trend'][str(horizon)]['mae_percentage_points'], 0)
            self.assertAlmostEqual(result['by_model']['flat'][str(horizon)]['mae_percentage_points'],
                                   math.expm1(.001 * horizon) * 100)
            self.assertEqual(result['by_model']['trend'][str(horizon)]['direction_hit_rate'], 1)
            self.assertEqual(result['by_model']['flat'][str(horizon)]['direction_signal_count'], 0)
            self.assertIsNone(result['by_model']['flat'][str(horizon)]['nonzero_signal_hit_rate'])

    def test_failures_are_not_replaced_or_compared_on_different_samples(self):
        cases = windows(fixture())
        records = [observation(case, 'flat', baseline(case)) for case in cases]
        records += [observation(cases[0], 'model', error='failed')]
        records += [observation(case, 'model', baseline(case)) for case in cases[1:]]
        result = metrics(cases, records, ['flat', 'model'])
        self.assertEqual(result['common_count'], 2)
        self.assertEqual(result['by_model']['model']['failures'], 1)
        self.assertEqual(result['by_model']['flat']['5']['n'], 2)
        self.assertEqual(metrics(cases, records, ['flat', 'not-run'])['common_count'], 0)

    def test_tampered_or_duplicate_predictions_are_rejected(self):
        cases = windows(fixture())
        row = observation(cases[0], 'flat', baseline(cases[0]))
        with self.assertRaises(ValueError):
            metrics(cases, [row, row], ['flat'])
        row['input_sha256'] = 'wrong'
        with self.assertRaises(ValueError):
            metrics(cases, [row], ['flat'])

    def test_bad_ohlcv_and_invalid_protocol_are_rejected(self):
        bars = fixture()['stocks'][0]['bars']
        for rows in [[bars[0], bars[0]], [dict(bars[0], close=float('nan'))],
                     [dict(bars[0], high=1)], [dict(bars[0], volume=-1)]]:
            with self.assertRaises(ValueError):
                validate_bars(rows)
        for kwargs in [dict(stride=20), dict(origins=100), dict(lookback=5)]:
            with self.assertRaises(ValueError):
                windows(fixture(), **kwargs)
        case = windows(fixture())[0]
        with self.assertRaises(ValueError):
            observation(case, 'invalid', {'5': float('inf'), '20': 0, '60': 0})
        changed = copy.deepcopy(fixture())
        changed['stocks'][0]['bars'][0]['close'] += 1
        self.assertNotEqual(fingerprint(fixture()), fingerprint(changed))

    def test_calendar_uses_weekdays_without_reading_future_labels(self):
        self.assertEqual(future_calendar('2026-01-02', 2), ['2026-01-05', '2026-01-06'])

    def test_numpy_returns_are_normalized_and_metrics_are_serializable(self):
        import json
        import numpy as np
        cases = windows(fixture())
        records = [observation(case, 'numpy', {str(h): np.float64(1) for h in HORIZONS})
                   for case in cases]
        self.assertIs(type(records[0]['predicted_return_pct']['5']), float)
        result = metrics(cases, records, ['numpy'])
        self.assertEqual(result['by_model']['numpy']['5']['direction_hit_rate'], 1)
        self.assertEqual(result['status'], 'complete')
        json.dumps(result, allow_nan=False)

    def test_observation_requires_prediction_or_error_and_reports_missing(self):
        cases = windows(fixture())
        with self.assertRaises(ValueError):
            observation(cases[0], 'invalid')
        with self.assertRaises(ValueError):
            observation(cases[0], 'invalid', baseline(cases[0]), error='failed')
        result = metrics(cases, [observation(cases[0], 'flat', baseline(cases[0]))], ['flat'])
        self.assertEqual(result['status'], 'partial')
        self.assertEqual(result['by_model']['flat']['missing'], 2)

    def test_chronos_covariates_only_use_history(self):
        import numpy as np
        case = windows(fixture())[0]
        changed = copy.deepcopy(case)
        for row in changed['future']:
            for field in ('open', 'high', 'low', 'close', 'volume', 'amount'):
                row[field] *= 100
        for covariates in (False, True):
            original = chronos_task(case, covariates)
            updated = chronos_task(changed, covariates)
            self.assertNotIn('future_covariates', original)
            np.testing.assert_array_equal(original['target'], updated['target'])
            self.assertEqual(original['target'].shape, (61,))
            if covariates:
                self.assertEqual(set(original['past_covariates']), set(PAST_COVARIATES))
                for field in PAST_COVARIATES:
                    expected = np.array([row[field] for row in case['history']], dtype=np.float32)
                    np.testing.assert_array_equal(original['past_covariates'][field], expected)
                    np.testing.assert_array_equal(original['past_covariates'][field], updated['past_covariates'][field])
            else:
                self.assertNotIn('past_covariates', original)

    def test_chronos_uses_median_and_exact_terminal_steps_without_cross_learning(self):
        import torch
        from unittest.mock import Mock
        case = windows(fixture())[0]
        last = case['history'][-1]['close']
        prices = torch.arange(1, 61, dtype=torch.float32).reshape(1, 60, 1) + 100
        runtime = ChronosRuntime.__new__(ChronosRuntime)
        runtime.covariates = True
        runtime.pipeline = Mock()
        runtime.pipeline.predict_quantiles.return_value = ([prices], [torch.full((1, 60), 10000)])
        result = runtime.predict(model_input(case), 42)
        for horizon in HORIZONS:
            self.assertAlmostEqual(result[str(horizon)], ((100 + horizon) / last - 1) * 100)
        args, kwargs = runtime.pipeline.predict_quantiles.call_args
        self.assertEqual(len(args[0]), 1)
        self.assertFalse(kwargs['cross_learning'])
        self.assertEqual(kwargs['quantile_levels'], [0.5])
        self.assertEqual(kwargs['context_length'], 61)
        runtime.pipeline.predict_quantiles.return_value = ([torch.zeros(1, 60, 1)], [])
        with self.assertRaises(ValueError):
            runtime.predict(model_input(case), 42)
        runtime.pipeline.predict_quantiles.return_value = ([torch.ones(60)], [])
        with self.assertRaises(ValueError):
            runtime.predict(model_input(case), 42)

    def test_chronos_rejects_origins_before_fixed_weight_release(self):
        import json
        from pathlib import Path
        pins = json.loads(Path(__file__).with_name('model_pins.json').read_text())
        cases = windows(fixture())
        validate_model_dates(cases, ['Chronos-2-close', 'Kronos-base'], pins)
        cases[0]['history'][-1]['date'] = '2025-10-29'
        with self.assertRaises(ValueError):
            validate_model_dates(cases, ['Chronos-2-ohlcv'], pins)


if __name__ == '__main__':
    unittest.main()
