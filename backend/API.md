# 市场预测 API · v1

基础地址：模拟器使用 `http://127.0.0.1:8787`，iPhone 真机使用电脑局域网地址，例如 `http://192.168.1.23:8787`。JSON 使用 `snake_case`，价格为 CNY；日期为 `YYYY-MM-DD`，更新时间为带时区的 ISO 8601。

默认模式为真实 AKShare 行情 + 模拟预测。先安装 `requirements.txt`，再运行 `python3 backend/server.py`。`--mode demo` 才使用纯模拟行情。运行 `python3 backend/generate_fixtures.py` 可重新生成离线演示样例，不会覆盖真实行情。

## 端点

| 方法 | 路径 | 返回 |
| --- | --- | --- |
| GET | `/health` | `{"status":"ok","mode":"live","market_source":"akshare","forecast_source":"mock"}` |
| GET | `/v1/assets` | 可搜索的 ETF／指数数组 |
| GET | `/v1/markets/{symbol}` | 报价、历史价格、三个周期的完整预测 |
| POST | `/v1/deliveries` | 创建演示下发，201 + 持久化回执 |
| GET | `/v1/deliveries` | 当前服务器保存的下发回执，最新在前 |

未找到的标的／路径返回 404。AKShare 上游失败或返回非法日线时返回 502，不自动降级成模拟行情。健康端点仅确认进程运行和模式，不代表上游可用。下发参数错误返回 400，空请求或请求体大于 16KB 返回 413。错误格式：`{"error":"描述"}`。当前无认证，默认绑定 `0.0.0.0` 支持局域网真机联调；仅在受信任网络中运行，仅需本机访问时可指定 `--host 127.0.0.1`。

行情使用最近 61 根完整、不复权日线。北京时间 15:10 前过滤当日日线，防止把盘中数据当作收盘；报价采用最后一根日线，涨跌幅对比前一根收盘，开高低和成交额来自同一根。每标的缓存 300 秒，到期后下一次请求重新获取。默认优先使用东方财富接口；其连接被临时断开时，自动使用 AKShare 新浪历史接口作为备用源。新浪指数接口不提供成交额时返回 `--`，不填造数据；两个数据源都失败才返回 502。

## 标的与行情

`GET /v1/assets` 返回 5 个精选标的的收盘报价数组。以下为结构示例，数值不是当前实时行情：

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
  source: "akshare",
  model: "RWKV · Mock",
  fetched_at: "2026-10-23T14:00:00+08:00",
  market_status: "daily_close",
  price_adjustment: "none",
  history: [{ date, close, volume }, ...],
  predictions: {
    "5":  Forecast,
    "20": Forecast,
    "60": Forecast
  }
}
```

`source` 仅表示行情来源，`akshare` 表示真实行情，`mock` 表示显式演示模式。无论行情模式如何，当前预测均为模拟。`as_of` 是收盘数据日期，`fetched_at` 是后端获取时间，不表示实时行情时间。演示响应不包含后三个新增元数据字段。

一次获取所有预测周期，切换周期无需再次网络请求。历史最后一个点的收盘价与报价完全一致，模拟预测以该价格为锚点，从下一演示交易日开始；未来日期仅跳过周末，仍需接入交易所节假日日历。真实行情日期不使用模拟交易日生成。

## Forecast 对象

```text
{
  id: "mock-akshare-510300-20-<行情内容摘要>",
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
  "prediction_id": "请替换成最近获取的 predictions[周期].id",
  "confidence": 95,
  "channel": "in_app"
}
```

`confidence` 为 80 或 95，省略时默认 80。`channel` 为 `in_app` 或 `webhook_demo`。客户端须先 GET 市场快照并使用其实际预测 ID；真实行情模式不接受离线模拟 ID。服务器将已经返回的预测保存在 SQLite，行情刷新后旧 ID 仍对应原来的行情与预测，避免内容漂移。

回执：

```json
{
  "id": "uuid",
  "prediction_id": "mock-akshare-510300-20-<行情内容摘要>",
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
    "explanation": "当时的模拟预测解读",
    "market_source": "akshare",
    "as_of": "2026-10-22T15:00:00+08:00"
  }
}
```

`delivered` 表示当前演示服务已保存回执。站内消息保存在当前设备／本地服务器；Webhook 不连接任何外部目标。真实下发需另行实现用户、授权渠道、幂等键、队列、重试和实际投递结果。客户端离线模式使用相同类型的回执并存入 UserDefaults；HTTP 模式额外写入服务器 SQLite。

## 成本口径

客户端估算公式：`输入 Token / 1,000,000 × 输入单价 + 输出 Token / 1,000,000 × 输出单价`，再乘以每日调用量和 30 日。输入／输出 Token、耗时和默认价格都是示例值。真实 RWKV 服务可以保留这些字段，也可以扩展 GPU 时长、缓存命中、并发数、模型版本与批量调用成本。

## AKShare 接入位置

`akshare_adapter.py` 已参与默认服务：ETF 优先使用 `fund_etf_hist_em(adjust="")`，指数优先使用 `stock_zh_index_daily_em`；失败后分别尝试 `fund_etf_hist_sina`／`stock_zh_index_daily`。快照的 `market_vendor` 为 `eastmoney` 或 `sina`，只表示 AKShare 上游行情来源，不输出任何预测。

- [ETF 行情与历史接口文档](https://akshare.akfamily.xyz/data/fund/fund_public.html)
- [指数行情与历史接口文档](https://akshare.akfamily.xyz/data/index/index.html)

后续将适配后的历史数据交给 RWKV 推理服务，替换当前按真实收盘价缩放的模拟分位数与模拟解读即可。
