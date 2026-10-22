# 市场预测 API · v1

基础地址示例：`http://127.0.0.1:8787`。JSON 使用 `snake_case`，价格为 CNY；日期为 `YYYY-MM-DD`，更新时间为带时区的 ISO 8601。

此服务用于产品联调，所有行情与预测均为可重复生成的模拟值。运行 `python3 backend/generate_fixtures.py` 可以重新生成客户端与服务器共享的数据文件。

## 端点

| 方法 | 路径 | 返回 |
| --- | --- | --- |
| GET | `/health` | `{"status":"ok","mode":"mock"}` |
| GET | `/v1/assets` | 可搜索的 ETF／指数数组 |
| GET | `/v1/markets/{symbol}` | 报价、历史价格、三个周期的完整预测 |
| POST | `/v1/deliveries` | 创建演示下发，201 + 持久化回执 |
| GET | `/v1/deliveries` | 当前服务器保存的下发回执，最新在前 |

未找到的标的／路径返回 404。下发参数错误返回 400，空请求或请求体大于 16KB 返回 413。错误格式：`{"error":"描述"}`。当前无认证，默认绑定 `127.0.0.1`，仅用于本地演示。

## 标的与行情

`GET /v1/assets` 返回数组，单条示例：

```json
{
  "symbol": "510300",
  "name": "沪深300ETF",
  "subtitle": "华泰柏瑞 · 上交所",
  "kind": "ETF",
  "price": 4.286,
  "change_percent": 1.32,
  "currency": "CNY",
  "volume": "28.64亿",
  "open": 4.247,
  "high": 4.32,
  "low": 4.217,
  "previous_close": 4.23
}
```

`kind` 是 `ETF` 或 `指数`，ETF 价格显示 3 位小数，指数显示 2 位。`change_percent` 的单位为百分比数值（1.32 表示 +1.32%）。`volume` 为已格式化成交额文本；历史点的 `volume` 是数值。生产接入可进一步统一成交额、成交量及单位。

`GET /v1/markets/510300` 返回：

```text
{
  asset: 上述报价对象,
  as_of: "2026-10-22T15:00:00+08:00",
  source: "mock",
  model: "RWKV · Demo",
  history: [{ date, close, volume }, ...],
  predictions: {
    "5":  Forecast,
    "20": Forecast,
    "60": Forecast
  }
}
```

本版本一次获取所有周期，切换周期无需再次网络请求。历史最后一个点是当前报价对应日期，预测从下一演示交易日开始；演示交易日仅跳过周末。真实数据需统一交易所日历、复权方法、时区和停牌处理。

## Forecast 对象

```text
{
  id: "demo-510300-20-20261022",
  horizon: 20,
  points: [{
    date: "2026-10-23",
    p025: number,
    p10: number,
    p25: number,
    p50: number,
    p75: number,
    p90: number,
    p975: number
  }, ...],
  trend: "震荡偏多",
  up_probability: 0.64,
  explanation: string,
  drivers: [{ title, value, detail, score }, ...],
  scenarios: [{ name, probability, target, detail }, ...],
  usage: { input_tokens: 4096, output_tokens: 1008, latency_ms: 1022 },
  backtest: {
    coverage: 0.812,
    sample_count: 240,
    median_error: 0.024,
    description: string
  }
}
```

| 字段 | 产品含义 |
| --- | --- |
| `points` | 每个未来交易日的预测分布，长度等于 `horizon` |
| `p025` / `p975` | 95% 中央预测区间 |
| `p10` / `p90` | 80% 中央预测区间 |
| `p25` / `p75` | 中间 50% 区间，图中深色区域 |
| `p50` | 中位走势，图中橙色虚线 |
| `up_probability` | 期末价格高于当前价格的概率，0–1 |
| `score` | 因素展示强度，0–1，当前未作为模型特征权重使用 |
| `scenarios` | 预设情景、展示概率和期末目标，概率之和为 1 |
| `backtest.coverage` | 固定 80% 区间的历史覆盖率展示值，0–1 |
| `backtest.median_error` | 中位价格预测的绝对百分比误差展示值，0–1 |

要求 `p025 ≤ p10 ≤ p25 ≤ p50 ≤ p75 ≤ p90 ≤ p975`，所有价格为有限正数，日期严格递增。页面的期末指标取 `points.last`，涨跌幅为 `(预测值 / 当前价 - 1) × 100%`。上涨概率与预测区间覆盖水平是不同指标。当前分位数和指标都是模拟设定，未做真实模型校准。

## 下发与回看

请求：

```json
{
  "symbol": "510300",
  "prediction_id": "demo-510300-20-20261022",
  "confidence": 95,
  "channel": "in_app"
}
```

`confidence` 为 80 或 95，省略时默认 80。`channel` 为 `in_app` 或 `webhook_demo`。服务器校验预测属于指定标的，并保存所选区间，避免回看时随页面切换而变化。

回执：

```json
{
  "id": "uuid",
  "prediction_id": "demo-510300-20-20261022",
  "symbol": "510300",
  "asset_name": "沪深300ETF",
  "channel": "in_app",
  "created_at": "2026-10-22T07:05:00+00:00",
  "status": "delivered",
  "forecast": {
    "horizon": 20,
    "confidence": 95,
    "lower": 3.9174,
    "median": 4.4617,
    "upper": 5.0059,
    "currency": "CNY",
    "decimals": 3,
    "explanation": "当时的预测解读"
  }
}
```

`delivered` 表示当前演示服务已保存回执。站内消息保存在当前设备／本地服务器；Webhook 不连接任何外部目标。真实下发需另行实现用户、授权渠道、幂等键、队列、重试和实际投递结果。客户端离线模式使用相同类型的回执并存入 UserDefaults；HTTP 模式额外写入服务器 SQLite。

## 成本口径

客户端估算公式：`输入 Token / 1,000,000 × 输入单价 + 输出 Token / 1,000,000 × 输出单价`，再乘以每日调用量和 30 日。输入／输出 Token、耗时和默认价格都是示例值。真实 RWKV 服务可以保留这些字段，也可以扩展 GPU 时长、缓存命中、并发数、模型版本与批量调用成本。

## AKShare 接入位置

`akshare_adapter.py` 提供可选的历史数据标准化与实时接口入口。它不参与当前模拟服务，也不输出任何预测。

- [ETF 行情与历史接口文档](https://akshare.akfamily.xyz/data/fund/fund_public.html)
- [指数行情与历史接口文档](https://akshare.akfamily.xyz/data/index/index.html)

真实接入时，将适配后的历史数据交给 RWKV 推理服务，再映射为上述分位数契约；不要将 AKShare 的行情接口视作预测接口。
