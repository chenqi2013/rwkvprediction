# 知势 · RWKV 市场预测

基于 SwiftUI 的 iOS ETF／指数预测原型，参考富途的行情详情结构。以「历史行情 → 概率走势 → 市场理解 → 预测下发」为主线，展示整段未来走势的区间，而不只是最高／最低目标价。

## 启动 iOS 应用

1. 使用 Xcode 26.4+ 打开 `rwkvprediction/rwkvprediction.xcodeproj`。
2. 选择 iOS 26.4+ 模拟器，运行 `rwkvprediction`。
3. 默认离线读取随包 JSON，不需要启动服务器或安装第三方依赖。

## 已实现

- 5 个演示标的：沪深300ETF、创业板ETF、科创50ETF、沪深300、上证指数；支持名称／代码搜索、分类与本地自选。
- 历史行情、5／20／60 个未来交易日的预测路径；80%／95% 预测区间、中间 50% 区间、中位走势，支持拖动查看某一天的数据。
- 期末区间上下沿、价格变动、上涨概率、走势解读、驱动因素、三种市场情景和回测指标。
- 站内消息／Webhook 演示下发、系统分享、下发记录持久化，保留当时的周期、区间和解读。
- 可填写内部 Token 单价、每日调用量的成本计算器；展示模拟输入／输出 Token 及耗时。
- 异步加载、下拉刷新、加载失败提示和重试。

## 使用 HTTP 模拟 API

```sh
python3 backend/server.py --port 8787
```

在 Xcode 的 Scheme → Run → Arguments → Environment Variables 设置：

```text
RWKV_API_BASE_URL = http://127.0.0.1:8787
```

运行后，应用通过 URLSession 获取同一套数据并调用下发接口。模拟器可以使用 localhost；真机应使用能访问的 HTTPS 地址。项目只为本地开发配置 `NSAllowsLocalNetworking`，没有全局禁用 ATS。

```sh
curl http://127.0.0.1:8787/v1/assets
curl http://127.0.0.1:8787/v1/markets/510300
curl -X POST http://127.0.0.1:8787/v1/deliveries \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"510300","prediction_id":"demo-510300-20-20261022","confidence":80,"channel":"in_app"}'
```

接口、分位数约定和接入边界见 [API.md](backend/API.md)。服务无需额外 Python 包，默认仅监听本机；下发记录保存在本地 SQLite 中。客户端也将本机收到的下发回执保存到 UserDefaults，重启后仍可查看。

## 接入 AKShare 和 RWKV

[AKShare 文档](https://akshare.akfamily.xyz/index.html)中的行情接口已映射到可选的 `backend/akshare_adapter.py`：

| 数据 | AKShare 接口 |
| --- | --- |
| ETF 实时行情 | `fund_etf_spot_em` |
| ETF 历史行情 | `fund_etf_hist_em`，前复权 `qfq` |
| 指数实时行情 | `stock_zh_index_spot_em` |
| 指数历史行情 | `index_zh_a_hist` |

该适配器按需导入 AKShare，使用真实行情时执行 `python3 -m pip install akshare`。当前模拟服务器**没有调用真实行情**；适配器中的外部接口未进行联网运行验证。

生产数据链路：AKShare → 清洗／复权／交易日对齐 → RWKV 推理 → 逐日分位数与解读 → 本项目的 HTTP 契约。AKShare 提供行情，不提供 RWKV 预测。真实模型需要返回有序分位数及通过校准的概率；成本估算器中的用量、延迟和默认单价均为示例，需替换为实测值。

## 验证

```sh
python3 -m unittest discover -s backend -v
```

测试覆盖所有标的和周期的分位数排序、历史与预测的时间边界、有效下发持久化，以及错误标的／预测 ID／区间／渠道的拒绝。

原生应用已在 iPhone 17 Pro（iOS 26.4）模拟器编译和运行；自动化交互验证包括周期、区间、搜索、行情／解读切换、下发和回看，以及 HTTP 模式的加载和下发。

## 演示数据边界

全部价格、预测、概率、回测、Token 和耗时均为固定模拟数据，页面中有明确标记。演示日期固定为 2026-10-22；日期生成仅排除周末，未接入交易所节假日日历。三种情景为产品展示设定，不表示真实统计结论。Webhook 仅生成演示回执，**不会请求外部系统或发送实际通知**。原型不包含真实模型权重、实盘交易或真实行情订阅。
