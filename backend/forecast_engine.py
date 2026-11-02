"""Replaceable local inference adapter and explicitly uncalibrated price projection.

Only the target returns and commentary come from the language model. Bands use
historical daily log-return volatility; they are not model confidence scores.
"""
import copy
import hashlib
import json
import math
import statistics
import threading
import time
from datetime import date, datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import ProxyHandler, Request, build_opener

from generate_fixtures import weekdays

VERSION = 'local-forecast-v1'
HORIZONS = (5, 20, 60)
QUANTILES = (('p025', -1.959964), ('p10', -1.281552), ('p25', -.67449),
             ('p50', 0), ('p75', .67449), ('p90', 1.281552), ('p975', 1.959964))
SCHEMA = dict(type='object', additionalProperties=False,
              required=[str(days) for days in HORIZONS],
              properties={str(days): dict(type='object', additionalProperties=False,
                                         required=['return_pct', 'summary'], properties=dict(
                                             return_pct=dict(type='number', minimum=-50, maximum=100),
                                             summary=dict(type='string', minLength=8, maxLength=240)))
                          for days in HORIZONS})


class ForecastUnavailable(Exception):
    pass


def market_features(snapshot):
    closes = [row['close'] for row in snapshot['history']]
    returns = [math.log(right / left) for left, right in zip(closes, closes[1:])]
    volatility = statistics.stdev(returns) if len(returns) > 1 else abs(returns[0])
    # A zero-volatility series still needs a non-degenerate experimental band.
    sigma = max(volatility, .0001)
    def change(window):
        return round((closes[-1] / closes[max(0, len(closes) - 1 - window)] - 1) * 100, 3)
    return dict(return_5d_pct=change(5), return_20d_pct=change(20),
                daily_log_volatility=sigma, history_days=len(closes),
                sma_5=round(statistics.mean(closes[-5:]), 4),
                sma_20=round(statistics.mean(closes[-20:]), 4))


class OpenAICompatibleForecastEngine:
    """Ollama today; any RWKV server with /chat/completions can replace it.

    Model output is validated before use. Failures never become mock forecasts.
    """
    def __init__(self, base_url='http://127.0.0.1:11434/v1', model='qwen2.5:0.5b',
                 timeout_seconds=30, structured_output=True):
        parsed = urlparse(base_url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username:
            raise ValueError('模型 base_url 必须为 HTTP(S) 地址')
        self.base_url = base_url.rstrip('/')
        self.model = model
        self.timeout = float(timeout_seconds)
        if not 1 <= self.timeout <= 120:
            raise ValueError('模型超时必须在 1–120 秒之间')
        self.structured_output = structured_output
        self.lock = threading.Lock()
        self.label = model

    def generate(self, snapshot):
        features = market_features(snapshot)
        asset = snapshot['asset']
        inputs = dict(name=asset['name'], symbol=asset['symbol'], as_of=snapshot['as_of'],
                      closing_price=asset['price'], features=features,
                      recent_closes=snapshot['history'][-20:])
        # Volume is not needed and differs in units across sources.
        inputs['recent_closes'] = [dict(date=row['date'], close=row['close'])
                                   for row in inputs['recent_closes']]
        system = ('你是本地行情实验助手。仅根据提供的历史收盘价和统计量，估计未来5、20、60个交易日的期末收益率。'
                  '这不是训练过的金融预测模型。不要编造新闻、资金流、财报或已验证概率。'
                  'return_pct单位为百分数，例如1.2表示+1.2%，负数表示下跌，必须在-50到100之间。'
                  'summary用简短中文说明未来判断与风险，必须说“未来”而非“过去”，不得把预估收益率说成已发生收益。'
                  '只输出JSON，格式为{"5":{"return_pct":数字,"summary":"中文"},'
                  '"20":{"return_pct":数字,"summary":"中文"},"60":{"return_pct":数字,"summary":"中文"}}。')
        messages = [dict(role='system', content=system),
                    dict(role='user', content=json.dumps(inputs, ensure_ascii=False, allow_nan=False) +
                         '\n请预测未来5、20、60日的收益率，不是复述过去收益率。summary说明未来可能走势和风险。')]
        request_body = dict(model=self.model, messages=messages, stream=False,
                            temperature=0, max_tokens=600)
        if self.structured_output:
            request_body['response_format'] = dict(type='json_schema', json_schema=dict(
                name='market_forecast', strict=True, schema=SCHEMA))
        else:
            request_body['response_format'] = dict(type='json_object')
        started = time.monotonic()
        if not self.lock.acquire(timeout=2):
            raise ForecastUnavailable('本地模型正在处理其他标的，请稍后重试。')
        try:
            request = Request(self.base_url + '/chat/completions',
                              data=json.dumps(request_body, ensure_ascii=False).encode(),
                              headers={'Content-Type': 'application/json'})
            with build_opener(ProxyHandler({})).open(request, timeout=self.timeout) as response:
                completion = json.load(response)
            choice = completion['choices'][0]
            if choice.get('finish_reason') != 'stop':
                raise ValueError('模型输出未正常完成')
            content = choice['message']['content']
            estimates = json.loads(content)
            if not isinstance(estimates, dict) or set(estimates) != {'5', '20', '60'}:
                raise ValueError('模型缺少完整的 5/20/60 日输出')
            for value in estimates.values():
                if not isinstance(value, dict):
                    raise ValueError('模型周期输出必须为对象')
                change = value.get('return_pct')
                summary = value.get('summary')
                if (isinstance(change, bool) or not isinstance(change, (float, int)) or
                        not math.isfinite(change) or not -50 <= change <= 100):
                    raise ValueError('模型目标收益率无效')
                if not isinstance(summary, str) or not 8 <= len(summary.strip()) <= 240:
                    raise ValueError('模型解读为空或过长')
            raw_usage = completion['usage']
            if any(type(raw_usage[key]) is not int or raw_usage[key] < 0
                   for key in ('prompt_tokens', 'completion_tokens')):
                raise ValueError('模型 Token 用量无效')
        except HTTPError as error:
            raise ForecastUnavailable(f'本地模型服务返回 HTTP {error.code}；请确认 {self.model} 已下载。未使用模拟预测替代。') from error
        except (URLError, TimeoutError, OSError) as error:
            raise ForecastUnavailable('本地模型连接失败或推理超时，请检查 Ollama 服务。未使用模拟预测替代。') from error
        except (ValueError, KeyError, TypeError, IndexError) as error:
            raise ForecastUnavailable(f'本地模型输出校验失败：{error}。未使用模拟预测替代。') from error
        finally:
            self.lock.release()
        usage = dict(input_tokens=raw_usage['prompt_tokens'], output_tokens=raw_usage['completion_tokens'],
                     latency_ms=round((time.monotonic() - started) * 1000), source='measured',
                     scope='一次调用生成全部三个周期，非每个周期各调用一次', model=self.model)
        return project(snapshot, estimates, features, usage, self.model, request_body)


def project(snapshot, estimates, features, usage, model, request_body):
    result = copy.deepcopy(snapshot)
    fingerprint = hashlib.sha256(json.dumps(dict(history=snapshot['history'], model=model,
                                                estimates=estimates, version=VERSION,
                                                request=request_body), sort_keys=True,
                                           ensure_ascii=False, allow_nan=False).encode()).hexdigest()[:16]
    result.update(model=model, forecast_source='local_model', forecast_method=VERSION,
                  forecast_description='本地模型生成目标收益率和解读；中位路径按目标插值，区间按历史波动估算，未经校准，尚无回测。',
                  generated_at=datetime.now(timezone.utc).isoformat())
    price = snapshot['asset']['price']
    sigma = features['daily_log_volatility']
    for horizon in HORIZONS:
        estimate = estimates[str(horizon)]
        target_log = math.log1p(estimate['return_pct'] / 100)
        points = []
        for index, day in enumerate(weekdays(date.fromisoformat(snapshot['history'][-1]['date']), horizon), 1):
            center = math.log(price) + target_log * index / horizon
            spread = sigma * math.sqrt(index)
            points.append(dict(date=day, **{key: round(math.exp(center + z * spread), 6)
                                           for key, z in QUANTILES}))
        probability = .5 * (1 + math.erf(target_log / (sigma * math.sqrt(horizon) * math.sqrt(2))))
        end = points[-1]
        result['predictions'][str(horizon)] = dict(
            id=f'local-{snapshot["asset"].get("id", snapshot["asset"]["symbol"])}-{horizon}-{fingerprint}',
            horizon=horizon, source='local_model', model=model, points=points,
            trend='偏多' if estimate['return_pct'] > .5 else '偏空' if estimate['return_pct'] < -.5 else '震荡',
            target_return_pct=estimate['return_pct'], up_probability=round(probability, 4),
            probability_source='historical_volatility_heuristic',
            interval_source='historical_log_return_volatility',
            explanation=f'{estimate["summary"].strip()}\n本地 {model} 实验输出；区间与上涨概率由历史波动公式估算，未经校准，不代表已验证的预测能力。',
            drivers=[dict(title='近5日涨跌', value=f'{features["return_5d_pct"]:+.2f}%',
                          detail='由历史收盘价计算，不是模型因子权重。', score=0),
                     dict(title='近20日涨跌', value=f'{features["return_20d_pct"]:+.2f}%',
                          detail='由可用历史收盘价计算，不包含新闻或资金流数据。', score=0),
                     dict(title='日收益波动', value=f'{sigma * 100:.2f}%',
                          detail='历史日对数收益率样本标准差，用于实验区间估算。', score=0)],
            scenarios=[dict(name=name, probability=probability, target=end[key],
                            detail='按实验区间取值；情景占比为展示设定，未经校准。')
                       for name, probability, key in [('上沿情景', .2, 'p90'), ('中位情景', .6, 'p50'), ('下沿情景', .2, 'p10')]],
            usage=copy.deepcopy(usage),
            backtest=dict(status='not_evaluated', coverage=0, median_error=0, sample_count=0,
                          description='尚未开展该模型的历史回测；覆盖率与误差暂无实测数据。'))
    return result


def configured_engine(path):
    config = json.loads(Path(path).read_text())
    provider = config.pop('provider')
    if provider == 'mock':
        return None
    if provider not in ('ollama', 'openai_compatible'):
        raise ValueError('不支持的预测 provider，请使用 ollama、openai_compatible 或 mock')
    return OpenAICompatibleForecastEngine(**config)
