"""AKShare daily bars, without price adjustment or synthetic fallback."""
import math
import logging
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

SHANGHAI = ZoneInfo('Asia/Shanghai')


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
    if len(result) < 61:
        raise ValueError('AKShare returned fewer than 61 complete daily bars')
    return result[-61:]


def history(symbol: str, kind: str, now=None) -> list[dict]:
    import akshare as ak
    now = now or datetime.now(SHANGHAI)
    arguments = dict(start_date=(now.date() - timedelta(days=400)).strftime('%Y%m%d'),
                     end_date=now.strftime('%Y%m%d'))
    if kind not in ('ETF', '指数'):
        raise ValueError('kind must be ETF or 指数')
    try:
        if kind == 'ETF':
            frame = ak.fund_etf_hist_em(symbol=symbol, period='daily', adjust='', **arguments)
            frame = frame.rename(columns={'日期': 'date', '开盘': 'open', '收盘': 'close', '最高': 'high',
                                          '最低': 'low', '成交量': 'volume', '成交额': 'amount'})
        else:
            frame = ak.stock_zh_index_daily_em(symbol='sh' + symbol, **arguments)
        bars = normalize(frame.to_dict(orient='records'), now)
        vendor = 'eastmoney'
    except Exception as error:
        logging.warning('Eastmoney daily history failed for %s; trying Sina: %s', symbol, error)
        market_symbol = ('sz' if symbol.startswith(('15', '16')) else 'sh') + symbol
        frame = ak.fund_etf_hist_sina(symbol=market_symbol) if kind == 'ETF' else ak.stock_zh_index_daily(symbol=market_symbol)
        bars = normalize(frame.to_dict(orient='records'), now, allow_missing_amount=kind == '指数')
        vendor = 'sina'
    for bar in bars:
        bar['data_vendor'] = vendor
    return bars
