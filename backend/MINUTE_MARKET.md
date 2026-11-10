# 分钟行情与 RWKV 输入

Flutter 顶部的折线图按钮进入「分钟行情」。也可从日线加载错误页的「查看分钟行情（无需模型）」进入，不需要先下载 Qwen。页面支持搜索股票、ETF、指数，切换数据源提供的交易日，拖动／鼠标悬停查看分钟 OHLC、成交量和成交额，刷新失败保留同一标的、同一天的原数据。

## 接口

```sh
# 该标的最近可用交易日的已完成分钟线
curl 'http://127.0.0.1:8787/v1/minute-markets/sh-stock-600519'

# 历史起点与固定实验集合统计；适用于制作无未来分钟的研究输入
curl 'http://127.0.0.1:8787/v1/minute-markets/sh-stock-600519?date=2026-11-09&at=10:45&include_market=1'
```

参数：`date=YYYY-MM-DD` 可选，必须是数据源提供的日期；`at=HH:MM` 可选，必须同时指定日期，返回该时刻及之前的 bar；`include_market=1` 可选，额外获取固定股票集合的同期统计。未知参数、重复参数、非法日期和未来日期返回 400。上游获取失败返回 502，不生成模拟数据；离线演示模式不提供分钟行情。

- `instrument` 保留市场／品种身份，避免把上证指数 `sh-index-000001` 当作平安银行 `sz-stock-000001`。
- `bars`：严格升序、上海本地时间的一分钟 OHLCV／成交额；`session` 标记日期及上午／下午。按时间戳为 bar 结束时间的保守口径过滤当前分钟，丢弃盘外／周末数据，不补造缺失分钟，不跨午休连接图表。
- `as_of` 是最后一根真实返回分钟的北京时间，不是假定为系统当前时间；`fetched_at` 是实际加载时间，缓存复用时保留原加载时间。页面明确显示数据截止时间，超过 3 分钟标记 `stale`（收盘后／休市也会标记最近可用数据）。没有承诺交易所实时或零延迟。
- 价格单位元、不复权。股票和 ETF 的 `volume_unit=share`（股）；指数成交量保留源口径，`volume_unit=source_units`，不作为模型输入。成交额单位元，不提供时为 null。
- 首选新浪的分钟 OHLCV 接口，通过带连接／读取超时的 HTTP 适配器访问；该接口与 AKShare `stock_zh_a_minute` 相同，但省略其额外的日线／前复权请求，`source=sina`。沪深股票失败时回退 AKShare 东方财富分钟接口，`source=akshare`。不把指数／ETF 代码发送到股票备用接口。
- 东方财富成交量单位为手，适配器乘 100 转股。其部分分钟开盘价为 0，这种情况返回 `open=null`，仅供收盘图查看，不推造开盘价；RWKV 输入会说明不可用。
- 每个标的缓存 20 秒，缓存身份包含市场／品种。刷新在缓存过期后取新数据；客户端使用手动／下拉刷新，没有后台轮询。

## 市场统计

`include_market=1` 仅适用于沪深 A 股股票。`backend/minute_universe.json` 固定了 8 只用于验证数据流程的股票，集合不随用户选择的标的或未来行情变化。这不是训练全集，也不是全市场，响应始终标记 `training_universe_match=false`，并返回集合 ID、成员清单、成员 ID 的 SHA256、各来源、加载失败成员以及各分钟实际样本数。

同一分钟内每个成员先计算 `100 * log(close / previous_close)`，再等权计算：

- `market_return`：收益均值。
- `market_volatility`：收益的总体标准差。
- `market_up_fraction`：严格正收益占比。

每个成员在新时段或缺失分钟之后的第一根 bar 不产生收益；同分钟缺失成员不填充、不用其他成员替换。无人产生有效收益时三个统计为 null，`count=0`。目标输出只查同一分钟，不用未来或其他时刻的统计替代。并行获取最多 4 个成员，复用同一缓存。

`rwkv_input` 检查最后连续时段是否从真实时段起始分钟开始、是否至少 65 根原始 bar、是否存在真实开盘价、同分钟市场统计是否可用、未来 30 分钟是否仍处于同一时段。`status=available` **仅表示输入形状与时间条件满足**，不表示训练分布一致、模型已校准或端侧模型已经运行。收盘后最后一段通常不能用于 30 分钟预测；可用 `date`／`at` 冻结上午／下午较早起点用于研究。

## 与本地 RWKV 原型连通

接口仅提供数据，不运行任何模型。完整响应或「接口数据导出与分享」保存的单次请求记录，可以作为研究 CPU 原型输入：

```sh
curl --fail \
  'http://127.0.0.1:8787/v1/minute-markets/sh-stock-600519?date=2026-11-09&at=10:45&include_market=1' \
  -o research/runtime/minute-input.json

research/.venv/bin/python research/rwkv7_predict.py \
  --input research/runtime/minute-input.json \
  --output research/runtime/minute-prediction-new.json
```

需要本机已下载前一轮固定权重；输出文件必须为新文件。脚本从最后连续时段完整前缀计算 23 维特征，再取最后 64 个编码 bar；前缀第一根仅作为收益锚点，不使用其不存在的市场收益。

2026-11-09 已用茅台当日 10:45 前的 75 根真实新浪分钟线、8 只实验股票的同期统计，在当前 Mac 上跑通真实权重的 CPU 原型，输出 30×9 分位数。输出仅用于数据链路验证，未与 CUDA 对齐，不将其当作回测、模型准确率或 App 端侧运行结果。原始响应和结果保存在本机忽略目录 `research/runtime/rwkv7-minute-live/`。

Flutter 现已接入独立 C++ CPU 运行库，通过 Dart FFI 在本设备进程内运行真实权重，并展示中位数、60%／80% 区间与后续真实行情对照。收盘后可选择较早的历史起点，推理输入严格截到该时刻；后续数据只参与对照指标。见 [端侧 RWKV 使用说明](../flutter_prediction/RWKV_MINUTE.md)。

同事尚未提供训练股票清单和真实 CUDA 对照输出。App 将此功能标为实验版，仍需核对训练统计集合、官方 CUDA 数值和区间覆盖率。Android／Windows 实机另行验证。

## 校验

```sh
backend/.venv/bin/python -m unittest discover -s backend -v
research/.venv/bin/python -m unittest discover -s research -v
cd flutter_prediction
flutter analyze
flutter test
```
