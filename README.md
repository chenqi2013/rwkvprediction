# 知势 · RWKV 市场预测

基于 SwiftUI 的 iOS ETF／指数预测原型，参考富途的行情详情结构。以「历史行情 → 概率走势 → 市场理解 → 预测下发」为主线，展示整段未来走势的区间，而不只是最高／最低目标价。

跨平台 Flutter 客户端位于 [`flutter_prediction`](flutter_prediction/README.md)，包含 Android、iOS、macOS、Windows 和 Linux 工程，复用当前 Python 后端。Flutter 已支持从 AKShare 名单搜索 A 股、ETF 和指数，选中任意搜索结果后展示真实日线与现有模拟预测，不再局限于原生原型的 5 个精选标的。运行方式见该目录的 README。

## 启动 iOS 应用

1. 使用 Xcode 26.4+ 打开 `rwkvprediction/rwkvprediction.xcodeproj`。
2. 选择 iOS 26.4+ 模拟器，运行 `rwkvprediction`。
3. 先按下一节启动 AKShare 后端。模拟器默认连接 `http://127.0.0.1:8787`；iPhone 真机请在右上角齿轮中填写电脑的局域网地址。

## 已实现

- 默认暗色外观；右上角齿轮 →「暗色模式」可切换明暗，自动保存选择，图表和弹窗同步适配。
- 5 个演示标的：沪深300ETF、创业板ETF、科创50ETF、沪深300、上证指数；支持名称／代码搜索、分类与本地自选。
- AKShare 最近完整交易日的收盘价、涨跌幅、开高低、成交额和近 60 个交易日历史行情；5／20／60 日模拟预测路径，支持拖动查看。
- 80%／95% 模拟预测区间、中间 50% 区间和中位走势，以真实收盘价为锚点缩放。
- 期末区间上下沿、价格变动、上涨概率、走势解读、驱动因素、三种市场情景和回测指标。
- 站内消息／Webhook 演示下发、系统分享、下发记录持久化，保留当时的周期、区间和解读。
- 可填写内部 Token 单价、每日调用量的成本计算器；展示模拟输入／输出 Token 及耗时。
- 异步加载、下拉刷新、加载失败提示和重试。

## 启动真实行情 API

```sh
python3 -m pip install -r backend/requirements.txt
python3 backend/server.py --host 0.0.0.0 --port 8787
```

建议在 Python 3.10+ 的虚拟环境中安装；Windows 可将 `python3` 替换为 `python`。后端默认 `--mode live`，使用 AKShare 从东方财富获取不复权日线。采用北京时间最近完整交易日数据：15:10 前排除当日未完成日线，之后允许当日日线。**当前不是盘中实时行情**。服务器每个标的缓存 5 分钟；下拉刷新会读取缓存到期后的新数据。

### iPhone 真机连接

1. 让手机与运行后端的电脑连接同一 Wi‑Fi。
2. 查看电脑与手机处于同一网段的 IP，在 macOS 系统网络设置中选择手机所连网络对应的网卡。电脑同时连接有线与 Wi‑Fi 时，它们的地址可能不同，不要直接假定 `en0` 就是 Wi‑Fi。
3. 在手机 Safari 打开 `http://电脑IP:8787/health`，确认返回 `status: ok`。
4. 点击 App 右上角齿轮或错误页「设置行情服务地址」，填写 `http://电脑IP:8787`，然后点击「保存并连接」。地址保存在手机上。
5. 首次访问请选择允许本地网络。如果此前拒绝，可在 iPhone 设置 → 隐私与安全性 → 本地网络中允许知势。

**真机的 `127.0.0.1` 是手机自身，不是电脑。** `0.0.0.0` 仅是后端监听地址，也不能填到手机里。若 Safari 不能访问健康端点，请检查电脑防火墙是否允许 Python 的入站连接，以及 Wi‑Fi 是否开启了客户端隔离。

### macOS 后台常驻

使用已安装依赖的虚拟环境执行 `backend/.venv/bin/python backend/install_macos_service.py`，将服务安装为当前用户的 LaunchAgent。安装前停止手动启动的后端，避免端口占用。服务会在用户登录后启动，异常退出后自动重启，关闭终端不影响运行。电脑休眠、关机或退出登录期间不可用。

日志位于 `backend/runtime/api.stdout.log` 和 `backend/runtime/api.stderr.log`。查看状态：`launchctl print gui/$(id -u)/com.rwkvprediction.market-api`。停用：`launchctl bootout gui/$(id -u)/com.rwkvprediction.market-api`；若不再需要登录启动，可删除 `~/Library/LaunchAgents/com.rwkvprediction.market-api.plist`。局域网 IP 可能随网络变化，变化后在 App 中更新地址。

2026-10-23 已在本机完成常驻部署，并用 iPhone 11（iOS 26.6.1）验证 `http://192.168.1.89:8787` 的加载。在 App 服务设置中检查系统本地网络权限并保存正确的 Wi‑Fi 地址后，已成功显示 AKShare 行情。这个地址是本次网络环境的地址，其他电脑需要替换。

也可以在 Xcode 的 Scheme → Run → Arguments → Environment Variables 设置（启动时优先于手机保存的地址）：

```text
RWKV_API_BASE_URL = http://192.168.1.23:8787
```

上述 IP 仅为示例，需替换为电脑的实际地址。模拟器可以使用 localhost；项目已配置本地网络权限说明和 `NSAllowsLocalNetworking`，没有全局禁用 ATS。生产环境使用 HTTPS。页面、分享和下发记录分别标记「AKShare · 日线收盘」与「模拟预测」。上游失败时返回 502 并提示重试，**不会自动换成模拟行情**。

```sh
curl http://127.0.0.1:8787/v1/assets
curl http://127.0.0.1:8787/v1/markets/510300
```

下发时使用行情响应中实际返回的 `predictions["20"].id`，不能使用固定示例 ID。接口、分位数约定和接入边界见 [API.md](backend/API.md)。服务默认监听 `0.0.0.0` 以支持局域网真机联调，当前无认证，仅在受信任网络中运行；只需模拟器时可加 `--host 127.0.0.1`。已返回的预测快照和下发记录保存在本地 SQLite 中，行情刷新后仍保留原预测。客户端另存本地回执，重启后仍可查看。

如系统代理导致东方财富连接被中断，可只对 `push2his.eastmoney.com` 配置 `NO_PROXY` 后重启后端。例如 macOS／Linux：`NO_PROXY=push2his.eastmoney.com python3 backend/server.py`；PowerShell：`$env:NO_PROXY="push2his.eastmoney.com"` 后运行后端。

## 离线演示（显式选择）

完全不联网时，在 Xcode Run 环境变量设置 `RWKV_DATA_MODE=demo`，应用读取随包 JSON。若需联调纯模拟 HTTP 服务，启动 `python3 backend/server.py --mode demo`，并移除客户端的 `RWKV_DATA_MODE`。两种模式都明确标记模拟行情。

## 数据与模型边界

[AKShare 文档](https://akshare.akfamily.xyz/index.html)中的日线接口已在 `backend/akshare_adapter.py` 中启用：

| 数据 | AKShare 接口 |
| --- | --- |
| ETF 日线／收盘报价 | `fund_etf_hist_em`，`adjust=""` 不复权 |
| 指数日线／收盘报价 | `stock_zh_index_daily_em`，明确使用 `sh000300`／`sh000001` |
| A 股日线／收盘报价 | `stock_zh_a_hist(adjust="")`，备用 `stock_zh_a_daily` |
| 可搜索的标的名单 | `stock_info_a_code_name`、`fund_etf_category_sina`、`index_stock_info` |

东方财富接口连接中断时，自动尝试 AKShare 的 `fund_etf_hist_sina`／`stock_zh_index_daily` 新浪历史接口。备用源仍为真实日线；其指数成交额缺失时展示 `--`，两个来源均失败才返回 502。

报价与历史曲线使用同一份日线，避免不同时间和复权口径混用。涨跌幅由最近两个完整交易日收盘价计算；成交额来自日线的 `成交额`／`amount`，按元换算成万／亿。历史成交量保留 AKShare 上游单位，不作为成交额展示。5 个标的的联网获取已经验证。

当前链路：AKShare → 日线清洗／校验 → 真实历史曲线和收盘报价 → 以收盘价缩放模拟预测 → 页面。价格校验包括有限正数、OHLC 顺序和至少 2 根完整日线，最多展示最近 61 根，不补造新上市标的的历史。

RWKV 尚未接入。未来区间、趋势、上涨概率、驱动因素、情景、回测、Token 用量和耗时仍为模拟；解读会明确说明真实行情日期与模拟边界。真实模型可以替换 `market_provider.live_snapshot` 中的模拟预测部分，保持 HTTP 契约不变。

## 验证

```sh
python3 -m unittest discover -s backend -v
```

测试覆盖分位数排序、日期边界、真实字段映射、收盘前过滤未完成日线、非法行情拒绝、缓存、上游失败 502、下发快照持久化，以及错误请求的拒绝。自动化测试使用隔离数据，不依赖上游网络。

原生工程编译通过；iPhone Duo（iOS 27.1）模拟器通过 2 项端到端测试，覆盖真实 AKShare 行情加载、ETF／指数切换、模拟预测周期切换和下发，以及离线演示的区间切换、行情／解读和记录回看。另在 iPhone 11 真机通过本地网络权限设置与行情加载测试。后端 9 项自动化测试通过。

## 演示数据边界

默认模式的行情来自 AKShare，实际日期以页面为准；仅显式离线演示模式使用固定 2026-10-22 模拟行情。未来预测日期暂仅排除周末，未接入交易所节假日日历。三种情景为产品展示设定，不表示真实统计结论。Webhook 仅生成演示回执，**不会请求外部系统或发送实际通知**。原型不包含真实模型权重或实盘交易。
