"""Local CPU porting trial, separate from the App's daily forecast pipeline."""

import argparse
import csv
import hashlib
import json
import time
from pathlib import Path

import numpy as np
import torch

from rwkv7_cpu import RWKV7CPU
from rwkv7_features import prepare_features


ROOT = Path(__file__).resolve().parent
PINS = json.loads((ROOT / 'rwkv7_pins.json').read_text())


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            checksum.update(chunk)
    return checksum.hexdigest()


def verify_model(directory):
    for name, expected in PINS['sha256'].items():
        if digest(directory / name) != expected:
            raise ValueError(f'Model package SHA256 mismatch: {name}')


def read_input(path):
    origin = None
    if path.suffix.lower() == '.json':
        document = json.loads(path.read_text())
        # Accept either the minute response or its API-export record envelope.
        if 'response' in document:
            document = document['response']['body']
        if (document.get('granularity'), document.get('timezone'), document.get('volume_unit')) != ('1m', 'Asia/Shanghai', 'share'):
            raise ValueError('Expected minute API response in Shanghai time and share volume units')
        if document.get('price_adjustment') != 'none' or document.get('source') not in ('sina', 'akshare'):
            raise ValueError('Expected real unadjusted minute data')
        if document['rwkv_input']['status'] != 'available':
            raise ValueError('Minute API input is unavailable: ' + '; '.join(document['rwkv_input']['reasons']))
        if document['instrument']['kind'] != '股票' or document['instrument']['market'] not in ('sh', 'sz'):
            raise ValueError('Model requires Shanghai/Shenzhen A-share stock input')
        rows = [row for row in document['bars'] if row['timestamp'] >= document['rwkv_input']['session_start']]
        stats = {row['timestamp']: row for row in document['market_statistics']['points']}
        timestamps = np.array([row['timestamp'] for row in rows], dtype='datetime64[us]')
        bars = np.array([[float(row[key]) for key in ('open', 'high', 'low', 'close', 'volume')] for row in rows])
        # The first raw bar anchors returns and is discarded. Cross-sectional
        # returns are intentionally unavailable there; the zero is NOT used as
        # an encoded model feature or substituted for any subsequent statistic.
        market = np.array([[0., 0., 0.] if index == 0 else
                           [float(stats[row['timestamp']][key]) for key in ('market_return', 'market_volatility', 'market_up_fraction')]
                           for index, row in enumerate(rows)], dtype=np.float32)
        features, anchor = prepare_features(bars, timestamps, market)
        origin = timestamps[-1].astype('datetime64[m]')
        start = int(timestamps[0].astype('datetime64[m]').astype(np.int64) % 1440)
        minute = int(origin.astype(np.int64) % 1440)
        if start not in (570, 571, 780, 781) or minute + 30 > (690 if minute < 720 else 900):
            raise ValueError('Incomplete session prefix or future horizon crosses session boundary')
    elif path.suffix.lower() == '.npz':
        with np.load(path, allow_pickle=False) as sample:
            features = np.array(sample['features'], dtype=np.float32)
            anchor_array = np.asarray(sample['anchor_price'])
            if anchor_array.ndim != 0:
                raise ValueError('anchor_price must be a scalar')
            anchor = float(anchor_array)
    else:
        with path.open(newline='') as stream:
            rows = list(csv.DictReader(stream))
        # Do not silently truncate timezone suffixes or seconds on conversion.
        stamps = [row['timestamp'] for row in rows]
        for stamp in stamps:
            if len(stamp) not in (16, 19) or stamp[10] not in ('T', ' ') or (len(stamp) == 19 and stamp[16:] != ':00'):
                raise ValueError('Use timezone-naive Shanghai minute timestamps')
        timestamps = np.array(stamps, dtype='datetime64[us]')
        bars = np.array([[float(row[k]) for k in ('open', 'high', 'low', 'close', 'volume')] for row in rows])
        market = np.array([[float(row[k]) for k in ('market_return', 'market_volatility', 'market_up_fraction')] for row in rows], dtype=np.float32)
        features, anchor = prepare_features(bars, timestamps, market)
        start = int(timestamps[0].astype('datetime64[m]').astype(np.int64) % 1440)
        if start not in (570, 571, 780, 781):
            raise ValueError('Supply the complete session prefix, not just the last 65 bars')
        origin = timestamps[-1].astype('datetime64[m]')
        minute = int(origin.astype(np.int64) % 1440)
        session_end = 690 if minute <= 690 else 900
        if minute + 30 > session_end:
            raise ValueError('The full 30-minute horizon must remain inside the same trading session')
    if features.shape != (64, 23) or not np.isfinite(features).all() or not np.isfinite(anchor) or anchor <= 0:
        raise ValueError('Expected finite unnormalized [64,23] features and positive anchor_price')
    return features, anchor, origin


def decode(raw, anchor, origin=None):
    raw = np.asarray(raw, dtype=np.float32)
    if raw.shape != (30, 9) or not np.isfinite(raw).all() or not np.isfinite(anchor) or anchor <= 0:
        raise ValueError('Invalid quantile output or anchor price')
    ordered = np.sort(raw, axis=-1)
    prices = anchor * np.exp(ordered.astype(np.float64) / 100)
    if not np.isfinite(prices).all():
        raise ValueError('Non-finite decoded prices')
    return [
        {
            'horizon_minutes': h + 1,
            'timestamp': str(origin + np.timedelta64(h + 1, 'm')) if origin is not None else None,
            'raw_cumulative_log_return_x100': raw[h].tolist(),
            'cumulative_log_return_x100': ordered[h].tolist(),
            'price_quantiles': prices[h].tolist(),
            'median_price': float(prices[h, 4]),
            'interval_60': prices[h, [1, 7]].tolist(),
            'interval_80': prices[h, [0, 8]].tolist(),
        }
        for h in range(30)
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', type=Path, default=ROOT / 'runtime/rwkv7-ashare-21m')
    parser.add_argument('--download', action='store_true', help='Download the immutable pinned model package first')
    parser.add_argument('--input', type=Path, required=True, help='Raw CSV, encoded NPZ, or minute API JSON/export record')
    parser.add_argument('--output', type=Path, required=True, help='New JSON file, never overwritten')
    parser.add_argument('--threads', type=int, default=4)
    args = parser.parse_args()
    if args.threads < 1:
        parser.error('--threads must be positive')
    if args.output.exists():
        parser.error('--output must be a new file')
    if args.download:
        from huggingface_hub import snapshot_download
        snapshot_download(PINS['repo'], revision=PINS['revision'], local_dir=args.model_dir,
                          allow_patterns=list(PINS['sha256']))
    verify_model(args.model_dir)
    features, anchor, origin = read_input(args.input)
    torch.set_num_threads(args.threads)
    start = time.perf_counter()
    model = RWKV7CPU(args.model_dir)
    loaded = time.perf_counter()
    raw = model.predict(torch.from_numpy(features).unsqueeze(0))[0].numpy()
    finished = time.perf_counter()
    result = {
        'model': PINS['repo'], 'revision': PINS['revision'],
        'runtime': 'experimental_pytorch_cpu_bf16_edges',
        'execution': 'local_process', 'cuda_parity': 'not_validated',
        'input_sha256': digest(args.input),
        'input_kind': 'publisher_synthetic_example' if digest(args.input) in (
            PINS['sha256']['example_bars.csv'], PINS['sha256']['example_inputs.npz']
        ) else 'user_provided_not_independently_verified',
        'feature_shape': list(features.shape), 'anchor_price': anchor,
        'horizon_unit': 'minute', 'quantile_levels': [i / 10 for i in range(1, 10)],
        'load_ms': (loaded - start) * 1000, 'inference_ms': (finished - loaded) * 1000,
        'threads': args.threads, 'torch_version': torch.__version__,
        'points': decode(raw, anchor, origin),
        'notes': [
            'CPU porting prototype; numerical parity with the official CUDA path is not validated.',
            'A sample forward pass is not a backtest or evidence of predictive accuracy.',
            'NPZ has no verified origin timestamp; minute offsets are relative when timestamps are null.',
            'Quantile intervals are model outputs; coverage is not calibrated for a new data source.',
            'Minute API market statistics use a fixed experimental universe; training-universe parity is unverified.',
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')
    print(f"Saved {args.output}: 30 × 9 quantiles; CPU inference {result['inference_ms']:.1f} ms; CUDA parity unvalidated")


if __name__ == '__main__':
    main()
