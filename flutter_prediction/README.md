# 知势 · RWKV / Flutter

从原 SwiftUI 页面迁移的跨平台客户端，使用同一份 AKShare 后端接口。由 Flutter 3.41.6 创建，包含 Android、iOS、macOS、Windows 和 Linux 平台目录。

## 启动

在仓库根目录启动后端（已部署 LaunchAgent 的电脑无需重复启动）：

```sh
backend/.venv/bin/python backend/server.py --host 0.0.0.0 --port 8787
```

然后启动 Flutter：

```sh
cd flutter_prediction
flutter pub get
flutter run -d macos
```

使用 `flutter devices` 查看设备，运行 `flutter run -d 设备ID`。Windows／Linux 桌面版分别在对应系统中执行 `flutter run -d windows`／`flutter run -d linux`，并安装 Flutter 所需的本机构建工具。iOS 真机需要在 `ios/Runner.xcworkspace` 中配置自己的签名。

默认连接地址：

| 运行环境 | 后端地址 |
| --- | --- |
| macOS／Windows／Linux、iOS 模拟器 | `http://127.0.0.1:8787` |
| Android 官方模拟器 | `http://10.0.2.2:8787` |
| Android／iOS 真机 | 右上角设置填写电脑的局域网 IP |

真机和电脑需在同一局域网，并允许本地网络访问。可在启动时指定默认值：

```sh
flutter run -d 设备ID --dart-define=API_BASE_URL=http://192.168.1.89:8787
```

手机保存的地址优先于启动默认值；右上角设置可随时修改。示例 IP 需替换为当前电脑地址。iOS 15+、macOS 12+；Android 最低版本由 Flutter 和插件配置确定。工程已配置 Android 网络权限、Apple 本地网络说明及 macOS 客户端网络权限，允许开发环境访问局域网 HTTP，正式部署应使用 HTTPS。

## 功能

- 默认暗色，明暗切换和自选标的本地保存。
- 手机单列、900 像素起双列布局；支持桌面鼠标、滚轮和键盘输入。
- AKShare 股票／ETF／指数名称与代码搜索、分类、分页；选中后按需加载真实收盘报价和最近最多 61 个交易日历史曲线，支持刷新及错误重试。
- 自选按市场、类别、代码区分并保存新标的，`000001` 的上证指数与平安银行不会混淆。名单获取失败明确提示，不作为“无结果”。
- 5／20／60 日模拟预测，80%／95% 区间和中间 50% 区间；拖动或鼠标悬停查看每天数值。
- 市场解读、驱动因素、情景、模拟回测、Token 成本计算与区间说明。
- 站内／Webhook 演示下发、复制摘要、持久化下发记录，回看当时区间与解读。Webhook 不发送外部请求。
- 设置 →「接口数据导出与分享」：每次实际 HTTP 请求分别保存一个 JSON，包含 URL、查询参数、POST 请求体、状态码、完整响应及耗时。支持预览、单个 JSON 分享，以及全部记录打包为 ZIP；桌面可选择保存位置，Android／iOS 使用系统分享（iOS 可存储到“文件”）。Linux 使用文件保存。

默认行情来自 AKShare；RWKV 走势、解读、回测和用量仍为模拟。上游失败显示错误，刷新失败保留原页面并明确提示。不会自动将真实行情替换为模拟数据。数据源及收盘日期在页面展示，接口详见 [backend/API.md](../backend/API.md)。

搜索范围为 A 股、场内 ETF 和 AKShare 指数名单，支持名称包含、代码、`sh600519` 等市场前缀，不含港美股和拼音。首次加载名单可能需要数秒，后台缓存 24 小时；新上市不足 2 个完整交易日时提示历史不足。请同步更新 Python 后端，新增端点为 `/v1/instruments`，新标的行情路径使用搜索返回的完整 `id`。

接口记录从此版本开始自动保存在设备应用支持目录的 `api_requests/`，重启后仍可读取。重复请求单独记录，接口错误、连接失败与超时也保留；未请求的接口不会补造记录，离线演示不会产生 HTTP 文件。记录中的 `response.body` 为解析后的 JSON，`body_text` 为响应文本，`body_base64` 保留完整响应字节；无 HTTP 响应时 `response` 为 null，并在 `error` 标明原因。导出仅打包已有记录，不重新请求行情或创建下发。ZIP 中每个请求对应一个独立 JSON 文件。

离线演示可在设置中显式开启（当前会话），或使用：

```sh
flutter run -d macos --dart-define=DEMO_MODE=true
```

## 校验与构建

```sh
flutter analyze
flutter test
flutter build apk --debug
flutter build ios --release --no-codesign
flutter build macos --debug
```

Windows 和 Linux 需在对应系统构建；未签名 iOS 产物不能直接安装到真机。Android 调试包位于 `build/app/outputs/flutter-apk/app-debug.apk`。

`lib/models.dart` 定义数据契约，`market_service.dart` 负责 HTTP 与显式离线模式，`market_controller.dart` 负责加载及持久化，`forecast_chart.dart` 绘制区间图，`market_page.dart` 与 `sheets.dart` 实现页面和弹窗。
