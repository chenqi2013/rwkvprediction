import argparse
import hashlib
import json
import math
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo


STOCKS = [('sh600519', '贵州茅台'), ('sz000001', '平安银行'), ('sh600036', '招商银行')]
FIELDS = ('open', 'high', 'low', 'close', 'volume', 'amount')


def validate_bars(rows):
    previous = ''
    result = []
    for row in rows:
        day = str(row['date'])[:10]
        date.fromisoformat(day)
        if day <= previous:
            raise ValueError('交易日期必须严格递增且不能重复')
        bar = {'date': day}
        for field in FIELDS:
            value = float(row[field])
            if not math.isfinite(value) or value < 0 or (field in FIELDS[:4] and value <= 0):
                raise ValueError(f'{day}: invalid {field}')
            bar[field] = value
        if not bar['low'] <= min(bar['open'], bar['close']) <= max(bar['open'], bar['close']) <= bar['high']:
            raise ValueError(f'{day}: invalid OHLC')
        previous = day
        result.append(bar)
    return result


def fingerprint(document):
    return hashlib.sha256(json.dumps(document, sort_keys=True, ensure_ascii=False, allow_nan=False).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description='冻结真实日线供模型比较，不修改在线行情服务')
    parser.add_argument('--output', type=Path, default=Path(__file__).parent / 'runtime/dataset.json')
    parser.add_argument('--end', default=None)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('数据文件已存在；请使用新路径保留原评估可复现性')
    import akshare as ak
    now = datetime.now(ZoneInfo('Asia/Shanghai'))
    cutoff = now.date() if (now.hour, now.minute) >= (15, 10) else now.date() - timedelta(days=1)
    end = min(date.fromisoformat(args.end), cutoff) if args.end else cutoff
    stocks = []
    for symbol, name in STOCKS:
        frame = ak.stock_zh_a_daily(symbol=symbol, start_date='20240101',
                                   end_date=end.strftime('%Y%m%d'), adjust='')
        rows = frame.to_dict(orient='records')
        if not rows or any('amount' not in row for row in rows):
            raise ValueError(f'{symbol}: 数据源缺少真实成交额，不以零或估值替代')
        bars = validate_bars(sorted((row for row in rows if str(row['date'])[:10] <= end.isoformat()),
                                    key=lambda row: str(row['date'])))
        if len(bars) < 300:
            raise ValueError(f'{symbol}: 历史不足 300 日')
        stocks.append(dict(symbol=symbol, name=name, bars=bars))
        print(f'{symbol} {name}: {len(bars)} rows, {bars[0]["date"]}..{bars[-1]["date"]}', flush=True)
    document = dict(schema_version=1, fetched_at=now.isoformat(), cutoff=end.isoformat(),
                    provider='AKShare/Sina stock_zh_a_daily', akshare_version=ak.__version__,
                    price_adjustment='none', volume_unit='shares', amount_unit='CNY', stocks=stocks)
    document['sha256'] = fingerprint(document)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=2, allow_nan=False), encoding='utf-8')
    print(f'Saved {args.output}: {document["sha256"]}')


if __name__ == '__main__':
    main()
