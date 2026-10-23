"""Combine real AKShare closing prices with explicitly simulated forecasts."""
import copy
import hashlib
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime

import akshare_adapter
from generate_fixtures import weekdays


class MarketUnavailable(Exception):
    pass


def amount_text(amount):
    if amount is None:
        return '--'
    return f'{amount / 100000000:,.2f}亿' if amount >= 100000000 else f'{amount / 10000:,.2f}万'


def live_snapshot(template, bars, fetched_at):
    snapshot = copy.deepcopy(template)
    asset = snapshot['asset']
    latest, previous = bars[-1], bars[-2]
    ratio = latest['close'] / asset['price']
    asset.update(price=latest['close'], previous_close=previous['close'],
                 change_percent=round((latest['close'] / previous['close'] - 1) * 100, 2),
                 open=latest['open'], high=latest['high'], low=latest['low'], volume=amount_text(latest['amount']))
    snapshot.update(source='akshare', model='RWKV · Mock', as_of=latest['date'] + 'T15:00:00+08:00',
                    fetched_at=fetched_at, market_status='daily_close', price_adjustment='none',
                    market_vendor=latest.get('data_vendor', 'eastmoney'),
                    history=[dict(date=bar['date'], close=bar['close'], volume=bar['volume']) for bar in bars])
    fingerprint = hashlib.sha256(json.dumps(bars, sort_keys=True).encode()).hexdigest()[:12]
    for forecast in snapshot['predictions'].values():
        horizon = forecast['horizon']
        forecast['id'] = f'mock-akshare-{asset["symbol"]}-{horizon}-{fingerprint}'
        dates = weekdays(date.fromisoformat(latest['date']), horizon)
        for point, day in zip(forecast['points'], dates):
            point['date'] = day
            for key in ('p025', 'p10', 'p25', 'p50', 'p75', 'p90', 'p975'):
                point[key] = round(point[key] * ratio, 4)
        for scenario in forecast['scenarios']:
            scenario['target'] = round(scenario['target'] * ratio, 4)
            scenario['detail'] = '模拟情景设定，不是实际模型推断。'
        forecast['explanation'] = (f'{asset["name"]}的真实行情截至{latest["date"]}，收盘价为{latest["close"]:g}。'
                                   f'以下{horizon}个交易日的区间、上涨概率和情景均为模拟，'
                                   '仅以真实收盘价为锚点缩放演示路径；尚未调用 RWKV 模型，不代表对市场趋势的判断。')
        for driver in forecast['drivers']:
            driver.update(value='模拟设定', detail='用于展示未来模型输出，不代表真实行情分析。')
    return snapshot


class MarketProvider:
    def __init__(self, fixtures, mode='live', history_loader=None, ttl=300):
        self.fixtures = fixtures
        self.mode = mode
        self.history_loader = history_loader or akshare_adapter.history
        self.ttl = ttl
        self.cache = {}
        self.locks = {symbol: threading.Lock() for symbol in fixtures['snapshots']}

    def snapshot(self, symbol):
        if symbol not in self.fixtures['snapshots']:
            raise KeyError(symbol)
        if self.mode == 'demo':
            return self.fixtures['snapshots'][symbol]
        with self.locks[symbol]:
            cached = self.cache.get(symbol)
            if cached and time.monotonic() - cached[0] < self.ttl:
                return cached[1]
            template = self.fixtures['snapshots'][symbol]
            for attempt in range(2):
                try:
                    bars = self.history_loader(symbol, template['asset']['kind'])
                    snapshot = live_snapshot(template, bars, datetime.now(akshare_adapter.SHANGHAI).isoformat(timespec='seconds'))
                    break
                except Exception as error:
                    if attempt == 1:
                        raise MarketUnavailable('AKShare 行情获取失败，请检查网络或稍后重试；未使用模拟行情替代。') from error
                    time.sleep(0.3)
            self.cache[symbol] = (time.monotonic(), snapshot)
            return snapshot

    def assets(self):
        with ThreadPoolExecutor(max_workers=1) as executor:
            snapshots = list(executor.map(self.snapshot, self.fixtures['snapshots']))
        return [snapshot['asset'] for snapshot in snapshots]
