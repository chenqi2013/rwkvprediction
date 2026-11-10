"""Completed, unadjusted minute bars and causal RWKV input preparation.

No inference, synthetic bars, gap filling or guessed market features here.
"""
import copy
import hashlib
import json
import logging
import math
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from pathlib import Path

from akshare_adapter import SHANGHAI
from instrument_catalog import instrument
from market_provider import MarketUnavailable

CONFIG = Path(__file__).with_name('minute_universe.json')


def session(timestamp):
    stamp = datetime.fromisoformat(timestamp)
    minute = stamp.hour * 60 + stamp.minute
    if 570 <= minute <= 690:
        return stamp.date().isoformat() + '-am'
    if 780 <= minute <= 900:
        return stamp.date().isoformat() + '-pm'
    return None


def normalize(records, vendor, now):
    """Treat source timestamps as Shanghai bar-end labels; exclude current minute.

    Eastmoney volume is in board lots (100 shares); Sina is in shares. Unknown
    Eastmoney zero opens stay null: they are not replaced with synthetic prices.
    """
    now = now.astimezone(SHANGHAI)
    cutoff = now.replace(second=0, microsecond=0, tzinfo=None)
    rows = {}
    for source in records:
        stamp = datetime.fromisoformat(str(source['timestamp']))
        if stamp.tzinfo is not None or stamp.second or stamp.microsecond:
            raise ValueError('Minute timestamps must be Shanghai-local, timezone-naive minute labels')
        if stamp >= cutoff or stamp.weekday() >= 5 or session(stamp.isoformat()) is None:
            continue
        row = {'timestamp': stamp.isoformat(timespec='minutes')}
        for field in ('open', 'high', 'low', 'close', 'volume', 'amount'):
            value = source.get(field)
            if field == 'amount' and value is None:
                row[field] = None
                continue
            value = float(value)
            if not math.isfinite(value) or value < 0:
                raise ValueError(f'Invalid minute {field}')
            if field == 'open' and value == 0 and vendor == 'eastmoney':
                row[field] = None
            else:
                if field in ('open', 'high', 'low', 'close') and value <= 0:
                    raise ValueError(f'Invalid minute {field}')
                row[field] = value * (100 if field == 'volume' and vendor == 'eastmoney' else 1)
        prices = [row['close']] + ([row['open']] if row['open'] is not None else [])
        if not row['low'] <= min(prices) <= max(prices) <= row['high']:
            raise ValueError('Invalid minute OHLC ordering')
        row['session'] = session(row['timestamp'])
        key = row['timestamp']
        if key in rows and rows[key] != row:
            raise ValueError('Conflicting duplicate minute bar')
        rows[key] = row
    result = [rows[key] for key in sorted(rows)]
    if not result:
        raise ValueError('No completed minute bars available')
    return {'bars': result, 'vendor': vendor}


def load_minutes(metadata, now):
    import akshare as ak
    import requests
    try:
        # Same Sina endpoint/contract as AKShare stock_zh_a_minute. Direct HTTP
        # adds a bounded timeout and avoids that function's extra daily/qfq
        # request, which is unnecessary for unadjusted minute data.
        response = requests.get(
            'https://quotes.sina.cn/cn/api/jsonp_v2.php/=/CN_MarketDataService.getKLineData',
            params={'symbol': metadata['market'] + metadata['symbol'], 'scale': '1', 'ma': 'no', 'datalen': '1970'},
            timeout=(5, 12))
        response.raise_for_status()
        text = response.text
        records = json.loads(text.split('=(', 1)[1].rsplit(');', 1)[0])
        records = [dict(row, timestamp=row['day']) for row in records]
        return normalize(records, 'sina', now)
    except Exception as error:
        logging.warning('Sina minute bars failed for %s: %s', metadata['id'], error)
        # The stock endpoint maps other identities incorrectly (e.g. SH index
        # 000001 versus SZ stock 000001). Never send those to this endpoint.
        if metadata['kind'] != '股票' or metadata['market'] not in ('sh', 'sz'):
            raise
    frame = ak.stock_zh_a_hist_min_em(symbol=metadata['symbol'], period='1', adjust='')
    records = frame.rename(columns={'时间': 'timestamp', '开盘': 'open', '收盘': 'close',
                                   '最高': 'high', '最低': 'low', '成交量': 'volume', '成交额': 'amount'}).to_dict('records')
    return normalize(records, 'eastmoney', now)


def bar_returns(bars):
    """First bar of every session or missing-minute boundary produces no return."""
    result = {}
    for previous, current in zip(bars, bars[1:]):
        if current['session'] == previous['session'] and (
            datetime.fromisoformat(current['timestamp']) - datetime.fromisoformat(previous['timestamp']) == timedelta(minutes=1)
        ):
            result[current['timestamp']] = 100 * math.log(current['close'] / previous['close'])
    return result


def aggregate_market(target, loaded):
    returns = {identity: bar_returns(value['bars']) for identity, value in loaded.items()}
    stats = []
    for bar in target:
        # Exact same-minute lookup only; neither forward nor backward fill.
        values = [series[bar['timestamp']] for series in returns.values() if bar['timestamp'] in series]
        mean = sum(values) / len(values) if values else None
        stats.append(dict(timestamp=bar['timestamp'], count=len(values),
                          market_return=mean,
                          market_volatility=math.sqrt(sum((x - mean) ** 2 for x in values) / len(values)) if values else None,
                          market_up_fraction=sum(x > 0 for x in values) / len(values) if values else None))
    return stats


def input_status(bars, statistics=None):
    last = bars[-1]
    origin = datetime.fromisoformat(last['timestamp'])
    tail = [last]
    for bar in reversed(bars[:-1]):
        if bar['session'] != last['session'] or datetime.fromisoformat(tail[0]['timestamp']) - datetime.fromisoformat(bar['timestamp']) != timedelta(minutes=1):
            break
        tail.insert(0, bar)
    start = datetime.fromisoformat(tail[0]['timestamp'])
    full_prefix = (start.hour, start.minute) in ((9, 30), (9, 31), (13, 0), (13, 1))
    end_minute = 690 if origin.hour < 12 else 900
    reasons = []
    if not full_prefix:
        reasons.append('连续时段起始分钟缺失，不能用截断窗口计算滚动特征')
    if len(tail) < 65:
        reasons.append(f'当前连续时段只有 {len(tail)} 根分钟线，至少需要 65 根')
    if origin.hour * 60 + origin.minute + 30 > end_minute:
        reasons.append('未来 30 分钟超出当前连续交易时段')
    if any(row['open'] is None for row in tail):
        reasons.append('数据源缺少真实分钟开盘价')
    if statistics is None:
        reasons.append('尚未加载同期市场统计')
    else:
        lookup = {row['timestamp']: row for row in statistics}
        # The first raw bar is only an anchor and its features are discarded.
        if any(lookup[row['timestamp']]['count'] == 0 for row in tail[1:]):
            reasons.append('部分历史分钟没有可用的市场统计')
    return dict(status='available' if not reasons else 'unavailable', reasons=reasons,
                context_bars=len(tail), full_session_prefix=full_prefix,
                session_start=tail[0]['timestamp'], origin=last['timestamp'],
                horizon_unit='minute', context_length=64, horizon=30,
                feature_contract='rwkv7-ashare-23-v1')


class MinuteMarket:
    def __init__(self, loader=None, now=None, ttl=20, universe=None):
        self.loader = loader or load_minutes
        self.now = now or (lambda: datetime.now(SHANGHAI))
        self.ttl = ttl
        self.universe = universe if universe is not None else json.loads(CONFIG.read_text())
        self.cache = {}
        self.locks = {}
        self.lock = threading.Lock()

    def _load(self, metadata):
        with self.lock:
            lock = self.locks.setdefault(metadata['id'], threading.Lock())
        with lock:
            cached = self.cache.get(metadata['id'])
            if cached and time.monotonic() - cached[0] < self.ttl:
                return copy.deepcopy(cached[1])
            try:
                value = self.loader(metadata, self.now())
            except Exception as error:
                raise MarketUnavailable(f'{metadata["name"]}分钟行情获取失败；未使用模拟数据替代，请稍后重试。') from error
            value['fetched_at'] = self.now().astimezone(SHANGHAI).isoformat(timespec='seconds')
            self.cache[metadata['id']] = (time.monotonic(), copy.deepcopy(value))
            return value

    def snapshot(self, metadata, *, day=None, at=None, include_market=False):
        if day is not None:
            if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', day):
                raise ValueError('date must be YYYY-MM-DD')
            parsed = datetime.strptime(day, '%Y-%m-%d').date()
            if parsed > self.now().astimezone(SHANGHAI).date():
                raise ValueError('不能请求未来日期')
        if at is not None:
            if not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d', at) or day is None:
                raise ValueError('at must be HH:MM and supplied with date')
        data = self._load(metadata)
        available = sorted({row['timestamp'][:10] for row in data['bars']}, reverse=True)
        day = day or available[0]
        bars = [row for row in data['bars'] if row['timestamp'].startswith(day) and (at is None or row['timestamp'][11:16] <= at)]
        if not bars:
            raise ValueError('数据源暂未提供该日期的分钟行情，请从可用日期中选择')
        stats = None
        market = None
        warnings = []
        if data['vendor'] == 'eastmoney' and any(bar['open'] is None for bar in bars):
            warnings.append('备用源部分分钟开盘价缺失，可查看收盘走势，不能用于完整 OHLCV 模型输入。')
        if include_market:
            if metadata['kind'] != '股票' or metadata['market'] not in ('sh', 'sz'):
                raise ValueError('RWKV 分钟输入仅面向沪深 A 股股票；ETF 和指数可查看分钟行情')
            items = [instrument(row['symbol'], row['name'], '股票') for row in self.universe['instruments']]
            loaded, failures = {}, []
            with ThreadPoolExecutor(max_workers=4) as pool:
                futures = {row['id']: pool.submit(self._load, row) for row in items}
                for identity, future in futures.items():
                    try:
                        loaded[identity] = future.result()
                    except MarketUnavailable:
                        failures.append(identity)
            stats = aggregate_market(bars, loaded)
            fingerprint = hashlib.sha256(json.dumps([row['id'] for row in items], separators=(',', ':')).encode()).hexdigest()
            market = dict(universe_id=self.universe['id'], universe_sha256=fingerprint,
                          instruments=items, size=len(items), loaded_count=len(loaded),
                          failed_instruments=failures, training_universe_match=False,
                          source_vendors={identity: value['vendor'] for identity, value in loaded.items()},
                          definition='同分钟已完成 bar 的 100*log(close/previous_close) 等权均值、总体标准差、正收益占比；每个连续时段首 bar 无收益',
                          points=stats)
            warnings.append('市场统计使用固定实验股票集合，尚未核对训练集合；不代表全市场。')
            if failures:
                warnings.append(f'{len(failures)} 个集合成员加载失败，各分钟实际样本数见 count；未用其他股票替换。')
        readiness = input_status(bars, stats)
        if metadata['kind'] != '股票' or metadata['market'] not in ('sh', 'sz'):
            readiness.update(status='unavailable', reasons=['该模型仅适用于沪深 A 股股票'])
        age = (self.now().astimezone(SHANGHAI) - datetime.fromisoformat(bars[-1]['timestamp']).replace(tzinfo=SHANGHAI)).total_seconds()
        stale = age > 180
        if stale:
            warnings.append('当前为最近可用分钟行情，时间可能落后于当前时刻，请核对数据截止时间。')
        return dict(schema_version=1, instrument=metadata, source='sina' if data['vendor'] == 'sina' else 'akshare', market_vendor=data['vendor'],
                    granularity='1m', timezone='Asia/Shanghai', price_adjustment='none',
                    volume_unit='source_units' if metadata['kind'] == '指数' else 'share', amount_unit='CNY',
                    timestamp_convention='bar_end; conservatively excludes current minute',
                    as_of=bars[-1]['timestamp'] + ':00+08:00',
                    fetched_at=data['fetched_at'],
                    stale=stale, date=day, available_dates=available, bars=bars,
                    market_statistics=market, rwkv_input=readiness,
                    forecast=dict(status='not_run', execution='on_device',
                                  reason='此接口仅提供行情与统计，请在客户端运行 RWKV 本地预测'),
                    warnings=warnings)
