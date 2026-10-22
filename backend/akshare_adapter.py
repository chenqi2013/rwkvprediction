"""Optional real historical data adapter. pip install akshare

This does NOT generate forecasts; feed its normalized data into a real RWKV
inference service. The demo server intentionally stays entirely synthetic.
"""
from datetime import date


def history(symbol: str, kind: str, start_date: str = '20260101') -> list[dict]:
    import akshare as ak
    arguments = dict(symbol=symbol, period='daily', start_date=start_date, end_date=date.today().strftime('%Y%m%d'))
    if kind == 'ETF':
        frame = ak.fund_etf_hist_em(**arguments, adjust='qfq')
    elif kind == '指数':
        frame = ak.index_zh_a_hist(**arguments)
    else:
        raise ValueError('kind must be ETF or 指数')
    records = []
    for _, row in frame.iterrows():
        records.append(dict(date=str(row['日期'])[:10], close=float(row['收盘']),
                            open=float(row['开盘']), high=float(row['最高']),
                            low=float(row['最低']), volume=float(row['成交量'])))
    return records


def spot(kind: str) -> list[dict]:
    import akshare as ak
    if kind == 'ETF':
        frame = ak.fund_etf_spot_em()
    elif kind == '指数':
        frame = ak.stock_zh_index_spot_em(symbol='沪深重要指数')
    else:
        raise ValueError('kind must be ETF or 指数')
    return frame.to_dict(orient='records')
