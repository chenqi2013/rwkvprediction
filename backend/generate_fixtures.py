"""Generate deterministic demo data; no market quotes or RWKV inference are implied."""
import json
import math
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = [
    ('510300', '沪深300ETF', '华泰柏瑞 · 上交所', 'ETF', 4.286, 1.32, 0.041, 0.083),
    ('159915', '创业板ETF', '易方达 · 深交所', 'ETF', 2.487, 2.16, 0.063, 0.115),
    ('588000', '科创50ETF', '华夏基金 · 上交所', 'ETF', 1.182, -0.67, 0.052, 0.132),
    ('000300', '沪深300', '中证指数 · 沪深市场', '指数', 4268.35, 1.25, 0.038, 0.078),
    ('000001', '上证指数', '上交所 · 上海市场', '指数', 3862.71, 0.86, 0.026, 0.064),
]
AS_OF = date(2026, 10, 22)

def weekdays(start, count, direction=1):
    result, day = [], start
    while len(result) < count:
        day += timedelta(days=direction)
        if day.weekday() < 5:
            result.append(day.isoformat())
    return result if direction > 0 else result[::-1]

def generate():
    assets, snapshots = [], {}
    for n, (symbol, name, subtitle, kind, price, change, drift, volatility) in enumerate(ASSETS):
        asset = dict(symbol=symbol, name=name, subtitle=subtitle, kind=kind,
                     price=price, change_percent=change, currency='CNY',
                     volume='28.64亿' if kind == 'ETF' else '4,862.3亿',
                     open=round(price * .991, 3), high=round(price * 1.008, 3),
                     low=round(price * .984, 3), previous_close=round(price / (1 + change / 100), 3))
        assets.append(asset)
        history = []
        for i, day in enumerate(weekdays(AS_OF + timedelta(days=1), 61, -1)):
            t = i / 60
            wave = math.sin(i * .49 + n) * .009 + math.sin(i * 1.79) * .004 + math.cos(i * .19) * .013
            endwave = math.sin(60 * .49 + n) * .009 + math.sin(60 * 1.79) * .004 + math.cos(60 * .19) * .013
            close = price * (.925 + .075 * t + wave - endwave * t)
            history.append(dict(date=day, close=round(close, 4), volume=120000000 + i * 1320000))
        history[-1]['close'] = price
        predictions = {}
        for horizon in (5, 20, 60):
            points = []
            future_dates = weekdays(AS_OF, horizon)
            for i, day in enumerate(future_dates):
                t = (i + 1) / horizon
                growth = drift * (horizon / 20) ** .72
                middle = price * (1 + growth * t + .0038 * math.sin(t * math.pi * 3) * math.sin(t * math.pi))
                spread = price * volatility * math.sqrt(horizon / 20) * math.sqrt(t)
                points.append(dict(date=day, p025=round(middle-spread*1.53,4), p10=round(middle-spread,4),
                                   p25=round(middle-spread*.52,4), p50=round(middle,4),
                                   p75=round(middle+spread*.52,4), p90=round(middle+spread,4), p975=round(middle+spread*1.53,4)))
            end = points[-1]
            predictions[str(horizon)] = dict(
                id=f'demo-{symbol}-{horizon}-20261022', horizon=horizon, points=points,
                trend='震荡偏多', up_probability=round(.64 + n*.012 - (horizon-20)*.0005,3),
                explanation=f'{name}近期价格重心上移，量价结构呈温和修复。模拟路径显示，未来{horizon}个交易日可能先震荡整理，再逐步上探。区间随时间拓宽，反映远期不确定性的增加。',
                drivers=[dict(title='趋势动量', value='偏多', detail='短期均线位于中期均线上方，价格重心抬升。', score=.76),
                         dict(title='量价关系', value='温和放量', detail='近期成交活跃度回升，为趋势提供一定支撑。', score=.62),
                         dict(title='波动风险', value='中等', detail='外部市场及政策变化可能放大短期价格波动。', score=.46)],
                scenarios=[dict(name='乐观情景', probability=.20, target=end['p90'], detail='风险偏好改善，增量资金持续流入'),
                           dict(name='基准情景', probability=.60, target=end['p50'], detail='维持当前量价结构，价格温和修复'),
                           dict(name='谨慎情景', probability=.20, target=end['p10'], detail='资金流入放缓，市场波动加大')],
                usage=dict(input_tokens=4096, output_tokens=768+horizon*12, latency_ms=842+horizon*9),
                backtest=dict(coverage=.812, sample_count=240, median_error=.024,
                              description='模拟回测指标，用于展示评估口径；并非真实模型表现。'))
        snapshots[symbol] = dict(asset=asset, as_of='2026-10-22T15:00:00+08:00',
                                 source='mock', model='RWKV · Demo', history=history, predictions=predictions)
    payload = dict(assets=assets, snapshots=snapshots, disclaimer='所有行情、预测、回测均为模拟数据，仅用于产品演示，不构成投资建议。')
    destination = ROOT / 'rwkvprediction/rwkvprediction/Resources/market-demo.json'
    destination.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n')
    return payload

if __name__ == '__main__':
    generate()
