"""AKShare daily bars, without price adjustment or synthetic fallback."""
import math
import logging
import threading
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

SHANGHAI = ZoneInfo('Asia/Shanghai')
SINA_LOCK = threading.Lock()


def normalize(records, now, allow_missing_amount=False):
    cutoff = now.date() if (now.hour, now.minute) >= (15, 10) else now.date() - timedelta(days=1)
    bars = {}
    for row in records:
        day = str(row['date'])[:10]
        if day > cutoff.isoformat():
            continue
        datetime.strptime(day, '%Y-%m-%d')
        bar = dict(date=day)
        for field in ('open', 'close', 'high', 'low', 'volume', 'amount'):
            if field == 'amount' and allow_missing_amount and row.get(field) is None:
                bar[field] = None
                continue
            value = float(row[field])
            if not math.isfinite(value) or value < 0 or (field in ('open', 'close', 'high', 'low') and value == 0):
                raise ValueError(f'Invalid {field} in AKShare response')
            bar[field] = value
        if not bar['low'] <= min(bar['open'], bar['close']) <= max(bar['open'], bar['close']) <= bar['high']:
            raise ValueError('Invalid OHLC ordering in AKShare response')
        bars[day] = bar
    result = [bars[day] for day in sorted(bars)]
    if len(result) < 2:
        raise ValueError('至少需要两个完整交易日，当前标的历史数据不足')
    return result[-61:]


def history(symbol: str, kind: str, now=None) -> list[dict]:
    import akshare as ak
    from instrument_catalog import instrument
    identity = instrument(symbol, symbol, kind)
    symbol = identity['symbol']
    market_symbol = identity['market'] + symbol
    now = now or datetime.now(SHANGHAI)
    arguments = dict(start_date=(now.date() - timedelta(days=400)).strftime('%Y%m%d'),
                     end_date=now.strftime('%Y%m%d'))
    try:
        if kind == 'ETF':
            frame = ak.fund_etf_hist_em(symbol=symbol, period='daily', adjust='', **arguments)
            frame = frame.rename(columns={'日期': 'date', '开盘': 'open', '收盘': 'close', '最高': 'high',
                                          '最低': 'low', '成交量': 'volume', '成交额': 'amount'})
        elif kind == '股票':
            frame = ak.stock_zh_a_hist(symbol=symbol, period='daily', adjust='', timeout=10, **arguments)
            frame = frame.rename(columns={'日期': 'date', '开盘': 'open', '收盘': 'close', '最高': 'high',
                                          '最低': 'low', '成交量': 'volume', '成交额': 'amount'})
        else:
            frame = ak.stock_zh_index_daily_em(symbol=market_symbol, **arguments)
        bars = normalize(frame.to_dict(orient='records'), now)
        vendor = 'eastmoney'
    except Exception as error:
        logging.warning('Eastmoney daily history failed for %s; trying Sina: %s', symbol, error)
        with SINA_LOCK:
            if kind == 'ETF':
                frame = ak.fund_etf_hist_sina(symbol=market_symbol)
            elif kind == '股票':
                frame = ak.stock_zh_a_daily(symbol=market_symbol, adjust='', **arguments)
            else:
                frame = ak.stock_zh_index_daily(symbol=market_symbol)
        bars = normalize(frame.to_dict(orient='records'), now, allow_missing_amount=kind == '指数')
        vendor = 'sina'
    for bar in bars:
        bar['data_vendor'] = vendor
    return bars
