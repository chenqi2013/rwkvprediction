import argparse
import hashlib
import json
import math
import platform
import statistics
import subprocess
import sys
import time
from datetime import date, timedelta
from pathlib import Path

from prepare_data import fingerprint, validate_bars
from chronos_runtime import ChronosRuntime, PAST_COVARIATES, VARIANTS


ROOT = Path(__file__).resolve().parent
HORIZONS = (5, 20, 60)
RELEASE_CUTOFF = '2025-09-10'


def validate_model_dates(cases, models, pins):
    for name in models:
        pin = pins['Chronos-2'] if name in VARIANTS else pins[name]
        cutoff = pin.get('available_after', RELEASE_CUTOFF)
        if any(case['history'][-1]['date'] < cutoff for case in cases):
            raise ValueError(f'{name}: 评估时点必须晚于固定权重公开版本（{cutoff}）')


def windows(dataset, origins=3, stride=60, lookback=61):
    if origins < 1 or stride < 60 or lookback < 21:
        raise ValueError('至少一个时点、间隔至少60日、历史至少21日')
    cases = []
    for stock in dataset['stocks']:
        bars = validate_bars(stock['bars'])
        for origin in range(len(bars) - 61 - stride * (origins - 1), len(bars) - 60, stride):
            if origin < lookback - 1 or bars[origin]['date'] < RELEASE_CUTOFF:
                raise ValueError('评估时点必须晚于公开模型版本，且有足够历史和完整60日标签')
            cases.append(dict(id=f'{stock["symbol"]}-{bars[origin]["date"]}',
                              symbol=stock['symbol'], name=stock['name'],
                              history=bars[origin - lookback + 1:origin + 1], future=bars[origin + 1:origin + 61]))
    if not cases or len({case['id'] for case in cases}) != len(cases):
        raise ValueError('样本为空或存在重复标的')
    return cases


def input_digest(case):
    return fingerprint(model_input(case))


def model_input(case):
    return {key: case[key] for key in ('id', 'symbol', 'name', 'history')}


def qwen_quote(case):
    history = case['history'][-61:]
    return dict(asset=dict(symbol=case['symbol'][2:], id=f'{case["symbol"][:2]}-stock-{case["symbol"][2:]}',
                           name=case['name'], kind='股票', price=history[-1]['close']),
                history=[dict(date=row['date'], close=row['close']) for row in history],
                as_of=f'{history[-1]["date"]}T15:00:00+08:00', source='akshare')


def baseline(case, trend=False):
    closes = [row['close'] for row in case['history']]
    daily = math.log(closes[-1] / closes[-21]) / 20 if trend else 0
    return {str(horizon): (math.exp(daily * horizon) - 1) * 100 for horizon in HORIZONS}


def future_calendar(last, count):
    current = date.fromisoformat(last)
    result = []
    while len(result) < count:
        current += timedelta(days=1)
        if current.weekday() < 5:
            result.append(current.isoformat())
    return result


class KronosRuntime:
    def __init__(self, name, device, source, samples):
        import torch
        from huggingface_hub import snapshot_download
        pins = json.loads((ROOT / 'model_pins.json').read_text())
        actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != pins['source']['revision']:
            raise ValueError('Kronos源码版本与model_pins.json不一致')
        sys.path.insert(0, str(source.resolve()))
        from model import Kronos, KronosTokenizer, KronosPredictor
        torch.set_num_threads(4)
        pin = pins[name]
        tokenizer_pin = pins[pin['tokenizer']]
        def download(spec):
            return snapshot_download(spec['repo'], revision=spec['revision'],
                                     allow_patterns=['config.json', 'model.safetensors'])
        started = time.perf_counter()
        tokenizer = KronosTokenizer.from_pretrained(download(tokenizer_pin))
        model = Kronos.from_pretrained(download(pin))
        self.predictor = KronosPredictor(model.eval(), tokenizer.eval(), device=device,
                                        max_context=pin['max_context'])
        self.load_ms = round((time.perf_counter() - started) * 1000)
        self.samples = samples

    def predict(self, case, seed):
        import numpy as np
        import pandas as pd
        import torch
        dates = future_calendar(case['history'][-1]['date'], max(HORIZONS))
        frame = pd.DataFrame(case['history'])
        torch.manual_seed(seed)
        np.random.seed(seed)
        predicted = self.predictor.predict(
            frame, pd.to_datetime(frame['date']), pd.Series(pd.to_datetime(dates)),
            pred_len=max(HORIZONS), sample_count=self.samples, T=1.0, top_p=.9, verbose=False)
        values = predicted['close'].tolist()
        if len(values) != max(HORIZONS) or any(not math.isfinite(value) or value <= 0 for value in values):
            raise ValueError('Kronos返回非法价格')
        last = float(frame['close'].iloc[-1])
        return {str(horizon): (values[horizon - 1] / last - 1) * 100 for horizon in HORIZONS}


def observation(case, model, predicted=None, error=None, latency_ms=None):
    if (predicted is None) == (error is None):
        raise ValueError('预测记录必须且只能包含有效预测或错误')
    if predicted is not None:
        if set(predicted) != {'5', '20', '60'} or any(not math.isfinite(value) for value in predicted.values()):
            raise ValueError('预测必须包含三个周期的有限收益率')
        predicted = {key: float(value) for key, value in predicted.items()}
    return dict(case_id=case['id'], input_sha256=input_digest(case), model=model,
                predicted_return_pct=predicted, error=error, latency_ms=latency_ms)


def metrics(cases, records, models):
    by_case = {case['id']: case for case in cases}
    indexed = {(row['case_id'], row['model']): row for row in records}
    if len(indexed) != len(records):
        raise ValueError('存在重复预测')
    for row in records:
        if row['input_sha256'] != input_digest(by_case[row['case_id']]):
            raise ValueError('预测与评估输入不匹配')
    common = [case['id'] for case in cases if all(
        indexed.get((case['id'], model), {}).get('predicted_return_pct') is not None for model in models)]
    groups = {}
    for model in models:
        values = {}
        for horizon in HORIZONS:
            errors, directions, active = [], [], []
            for identity in common:
                case = by_case[identity]
                actual = (case['future'][horizon - 1]['close'] / case['history'][-1]['close'] - 1) * 100
                predicted = indexed[identity, model]['predicted_return_pct'][str(horizon)]
                errors.append(predicted - actual)
                if abs(actual) > 1e-10:
                    hit = int(predicted * actual > 0)
                    directions.append(hit)
                    if abs(predicted) > 1e-10:
                        active.append(hit)
            values[str(horizon)] = dict(
                n=len(errors), mae_percentage_points=statistics.mean(map(abs, errors)) if errors else None,
                rmse_percentage_points=math.sqrt(statistics.mean(value * value for value in errors)) if errors else None,
                direction_hit_rate=statistics.mean(directions) if directions else None,
                nonzero_signal_hit_rate=statistics.mean(active) if active else None,
                direction_signal_count=len(active), direction_label_count=len(directions))
        model_rows = [row for row in records if row['model'] == model]
        values['failures'] = sum(row['error'] is not None for row in model_rows)
        values['attempted'] = len(model_rows)
        values['missing'] = len(cases) - len(model_rows)
        groups[model] = values
    return dict(status='complete' if all(values['missing'] == 0 for values in groups.values()) else 'partial',
                common_case_ids=common, common_count=len(common), total_cases=len(cases), by_model=groups)


def write_report(output, dataset, cases, records, configuration, loads):
    summary = metrics(cases, records, configuration['models'])
    labels = {case['id']: {str(h): (case['future'][h - 1]['close'] / case['history'][-1]['close'] - 1) * 100
                          for h in HORIZONS} for case in cases}
    document = dict(dataset_sha256=dataset['sha256'], configuration=configuration,
                    model_load_ms=loads, actual_return_pct=labels, summary=summary, observations=records)
    (output / 'results.json').write_text(json.dumps(document, ensure_ascii=False, indent=2, allow_nan=False), encoding='utf-8')
    lines = ['# 金融模型滚动评估', '',
             '固定小样本初筛；未调参、未训练，未用于自动替换客户端。', '',
             f'运行状态：{summary["status"]}（complete表示各模型均完成尝试，失败数另列）。',
             f'行情数据指纹：`{dataset["sha256"]}`；来源：{dataset["provider"]}；不复权价格。',
             f'完整共同样本：{summary["common_count"]}/{len(cases)}个时点；每只股票各时点间隔至少60个交易日。',
             '输入只取时点之前61根日线。Kronos使用OHLC、成交量和成交额；Qwen沿用客户端提示词。',
             'Chronos-2-close只用收盘价；Chronos-2-ohlcv额外输入历史开高低价、成交量和成交额，无未来协变量、无跨时点联合学习。',
             '评估时点晚于所选固定权重的公开版本；训练集截止与预训练污染无法完全审计。',
             'Kronos用工作日历推算未来日期，不读取未来真实日期。节假日和停牌可能造成时间特征偏差。',
             '不复权避免事后前复权，但分红/拆股影响价格收益；不代表含分红总收益。预选现存股票有选择偏差。',
             '预测点为Kronos采样均值、Chronos的0.5分位数、Qwen期末目标；不比较未校准区间，不模拟交易收益。', '',
             '| 模型 | 周期 | 共同样本数 | 收益率MAE（百分点） | RMSE（百分点） | 方向命中率 | 非零方向信号数 |',
             '|---|---:|---:|---:|---:|---:|---:|']
    def fmt(value, percent=False):
        return '—' if value is None else f'{value * 100:.1f}%' if percent else f'{value:.3f}'
    for model, values in summary['by_model'].items():
        for horizon in HORIZONS:
            row = values[str(horizon)]
            lines.append(f'| {model} | {horizon} | {row["n"]} | {fmt(row["mae_percentage_points"])} | '
                         f'{fmt(row["rmse_percentage_points"])} | {fmt(row["direction_hit_rate"], True)} | {row["direction_signal_count"]} |')
    lines += ['', '实际收益为零的样本不计方向；预测为零是弃权且不算命中。价格不变基线不能据方向命中率评价。',
              '各周期单独计分，同一时点的5/20/60日不能视为三个独立样本；股票之间也存在相关性。', '', '## 成功率与耗时', '']
    for model, values in summary['by_model'].items():
        latencies = [row['latency_ms'] for row in records if row['model'] == model and row['latency_ms'] is not None]
        lines.append(f'- {model}：失败{values["failures"]}/{values["attempted"]}，未尝试{values["missing"]}；'
                     f'每时点中位耗时{statistics.median(latencies) if latencies else "—"} ms。')
    lines += ['', 'Qwen耗时含每次模型加载，Kronos及Chronos预先加载；加载耗时另存JSON，不能直接比较Qwen引擎速度。',
              '失败不替换为基线；主表只比较所有指定模型均成功的相同样本。详细错误见results.json。', '',
              '## 评估时点', '', *[f'- {case["id"]} → 最后标签{case["future"][-1]["date"]}' for case in cases], '',
              '## 使用结论', '', '样本太少，不能确定任何模型有稳定优势。继续扩大预先固定的股票池、时间范围与随机种子，'
              '在全新时段检验；交易策略还需纳入手续费、滑点、分红、停牌和风险约束。']
    (output / 'REPORT.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description='Kronos、Chronos-2与现有端侧Qwen的相同时点滚动评估')
    parser.add_argument('--dataset', type=Path, default=ROOT / 'runtime/dataset.json')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--models', nargs='+', choices=['Kronos-mini', 'Kronos-small', 'Kronos-base', *VARIANTS],
                        default=['Kronos-mini', 'Kronos-small'])
    parser.add_argument('--source', type=Path, default=ROOT / 'runtime/Kronos')
    parser.add_argument('--device', choices=['cpu', 'mps', 'cuda'], default='cpu')
    parser.add_argument('--origins', type=int, default=3)
    parser.add_argument('--stride', type=int, default=60)
    parser.add_argument('--samples', type=int, default=3)
    parser.add_argument('--seed', type=int, default=42)
    parser.add_argument('--qwen-model', type=Path)
    parser.add_argument('--flutter', default='flutter')
    args = parser.parse_args()
    if args.samples < 1 or len(set(args.models)) != len(args.models):
        parser.error('模型或采样次数不合法')
    if args.output.exists():
        parser.error('输出目录已存在；请使用新目录保存独立运行')
    args.output.mkdir(parents=True)
    dataset = json.loads(args.dataset.read_text(encoding='utf-8'))
    claimed = dataset.pop('sha256')
    if fingerprint(dataset) != claimed:
        raise ValueError('冻结行情指纹不匹配')
    dataset['sha256'] = claimed
    cases = windows(dataset, args.origins, args.stride)
    pins = json.loads((ROOT / 'model_pins.json').read_text())
    validate_model_dates(cases, args.models, pins)
    (args.output / 'dataset.json').write_text(json.dumps(dataset, ensure_ascii=False, allow_nan=False), encoding='utf-8')
    records, loads = [], {}
    config = dict(origins=args.origins, stride=args.stride, lookback=61, horizons=HORIZONS,
                  samples=args.samples, seed=args.seed, device=args.device,
                  models=['no-change', 'trend-20d', *args.models, *(['Qwen-device'] if args.qwen_model else [])],
                  pins=pins)
    config['model_settings'] = {
        name: dict(point_estimate='median', target='close', dtype='float32', context_length=61,
                   past_covariates=list(PAST_COVARIATES) if name == 'Chronos-2-ohlcv' else [],
                   future_covariates=[], cross_learning=False, batch_size=8)
        for name in args.models if name in VARIANTS}
    config['model_parameter_counts'] = {}
    config['environment'] = dict(python=sys.version, system=platform.platform())
    config['source_sha256'] = {
        str(path.relative_to(ROOT.parent)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [ROOT / 'evaluate.py', ROOT / 'prepare_data.py', ROOT / 'chronos_runtime.py',
                     ROOT.parent / 'flutter_prediction/lib/device_model.dart',
                     ROOT.parent / 'flutter_prediction/lib/device_forecast.dart',
                     ROOT.parent / 'flutter_prediction/test/device_forecast_batch_test.dart']}
    if args.qwen_model:
        with args.qwen_model.open('rb') as model_file:
            config['qwen_gguf_sha256'] = hashlib.file_digest(model_file, 'sha256').hexdigest()
    packages = ['torch', 'numpy', 'pandas', 'huggingface_hub', 'safetensors']
    if any(name in VARIANTS for name in args.models):
        packages += ['chronos-forecasting', 'transformers', 'accelerate']
    for package in packages:
        from importlib.metadata import version
        config['environment'][package] = version(package)
    try:
        for case in cases:
            for name, trend in [('no-change', False), ('trend-20d', True)]:
                records.append(observation(case, name, baseline(case, trend)))
        for name in args.models:
            print(f'Loading {name}', flush=True)
            runtime = (ChronosRuntime(name, args.device) if name in VARIANTS
                       else KronosRuntime(name, args.device, args.source, args.samples))
            if hasattr(runtime, 'parameter_count'):
                config['model_parameter_counts'][name] = runtime.parameter_count
            loads[name] = runtime.load_ms
            for index, case in enumerate(cases):
                started = time.perf_counter()
                try:
                    predicted = runtime.predict(model_input(case), args.seed + index)
                    row = observation(case, name, predicted, latency_ms=round((time.perf_counter() - started) * 1000))
                except Exception as error:
                    row = observation(case, name, error=str(error))
                records.append(row)
                print(f'{name} {case["id"]}: {row["error"] or row["predicted_return_pct"]}', flush=True)
                write_report(args.output, dataset, cases, records, config, loads)
            del runtime
        if args.qwen_model:
            batch = [dict(id=case['id'], input_sha256=input_digest(case), quote=qwen_quote(case)) for case in cases]
            batch_path = (args.output / 'qwen-input.json').resolve()
            result_path = (args.output / 'qwen-output.jsonl').resolve()
            batch_path.write_text(json.dumps(batch, ensure_ascii=False), encoding='utf-8')
            command = [args.flutter, 'test', 'test/device_forecast_batch_test.dart',
                       f'--dart-define=DEVICE_MODEL_PATH={args.qwen_model.resolve()}',
                       f'--dart-define=DEVICE_BATCH_PATH={batch_path}',
                       f'--dart-define=DEVICE_BATCH_RESULT_PATH={result_path}']
            with (args.output / 'qwen.log').open('w', encoding='utf-8') as log:
                completed = subprocess.run(command, cwd=ROOT.parent / 'flutter_prediction', stdout=log, stderr=subprocess.STDOUT)
            responses = [json.loads(line) for line in result_path.read_text(encoding='utf-8').splitlines()] if result_path.exists() else []
            indexed = {row['id']: row for row in responses}
            for case in cases:
                row = indexed.get(case['id'])
                if row is None or row.get('input_sha256') != input_digest(case):
                    records.append(observation(case, 'Qwen-device', error=f'Qwen未返回匹配样本，退出码{completed.returncode}'))
                else:
                    records.append(observation(case, 'Qwen-device', predicted=row.get('predicted_return_pct'),
                                               error=row.get('error'), latency_ms=row.get('latency_ms')))
    finally:
        write_report(args.output, dataset, cases, records, config, loads)
    print(f'Report: {args.output / "REPORT.md"}', flush=True)


if __name__ == '__main__':
    main()
