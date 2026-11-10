# 知势 · RWKV / Flutter

跨平台行情客户端，支持 Android、iOS、macOS、Windows 和 Linux。预测统一使用本设备的 RWKV7 21M 模型，日线页面展示报价和历史曲线，查看行情无需安装模型。

## 启动

在仓库根目录启动行情后端：

```sh
python -m pip install -r backend/requirements.txt
python backend/server.py --host 0.0.0.0 --port 8787
```

在 Flutter 目录运行 Windows 版本：

```sh
flutter pub get
flutter run -d windows
```

项目要求 Dart 3.11.4 或更新的兼容版本。Windows 开发环境当前使用 Flutter 3.41.7；请确认终端与编辑器使用同一 SDK。其他平台使用 `flutter devices` 查看设备后，以对应设备 ID 运行。Windows 需要安装 Visual Studio 的 C++ 桌面开发工具。

行情服务地址固定为 `http://218.17.184.73:8787`，所有平台统一连接。设置页只读显示地址，旧版保存的地址和 `API_BASE_URL` 启动参数不再覆盖它。使用已部署的服务时无需本地启动后端。

## RWKV 分钟预测

从顶部「分钟行情」、底部「RWKV／分钟预测」或设置中的「RWKV 分钟预测」进入。选择沪深 A 股股票，加载同期市场统计，然后下载约 40 MiB 的六个 safetensors 分片；桌面也可导入包含原始分片的目录。模型固定版本并逐文件校验 SHA-256，重试会复用已校验的完整分片。

模型默认通过 `https://hf-mirror.com` 镜像下载，保留固定版本及逐文件 SHA-256 校验。Windows 下载支持系统手动配置的 HTTP／HTTPS 代理和绕过列表。变更代理设置后重新下载即可。Windows 权重和推理文件保存在可执行文件所在目录的 `models/rwkv7-ashare-21m/`，与启动时的工作目录无关；其他平台保存在设备应用支持目录。模型不随应用包分发，移动 Windows 程序时可一起带上 `models` 目录。

模型在本设备通过独立 C++ CPU 运行库预测未来 30 分钟，展示中位数及 60%／80% 区间。推理无需 Python、Torch、CUDA 或模型服务器。模型仅对沪深股票启用；ETF／指数可查看分钟行情。预测需要连续历史窗口及有效起点，不能跨午休或收盘。历史起点之后的数据只用于结果对照，不进入模型输入。

模型仍为实验版，同期市场统计使用固定实验集合，区间尚未校准。输入要求、实现细节及数值验证见 [RWKV_MINUTE.md](RWKV_MINUTE.md)，行情接口见 [分钟行情文档](../backend/MINUTE_MARKET.md)。

## 行情与其他功能

- AKShare 股票／ETF／指数名称与代码搜索、分类、分页，以及本地自选和明暗主题保存。
- 日线报价、最近最多 61 个交易日历史曲线，支持刷新、错误重试、拖动和鼠标悬停。桌面支持全屏查看及 Esc 退出，手机支持横屏查看。
- 分钟行情支持交易日选择、标的切换、OHLC、成交量和刷新，页面标明实际数据截止时间。
- 设置中的「接口数据导出与分享」保存实际 HTTP 请求、完整响应和耗时，可预览、分享单个 JSON 或打包 ZIP。离线演示不生成 HTTP 记录。

日线只请求 `?inference=device` 行情接口，不调用后端预测服务。上游失败显示错误，刷新失败保留原行情。日线服务接口见 [backend/API.md](../backend/API.md)。

设置中可显式开启本次会话的离线演示，或启动时传入 `--dart-define=DEMO_MODE=true`。该模式只展示五个标的的样例日线，不生成预测；RWKV 分钟预测需要真实分钟行情与同期市场统计。

## 校验与构建

```sh
flutter analyze
flutter test
flutter build windows --debug
```

其他平台在对应构建环境执行 `flutter build apk`、`flutter build ios`、`flutter build macos` 或 `flutter build linux`。真实权重推理对照测试可设置 `RWKV_TEST_MODEL_DIR` 为原始六分片目录后执行 `flutter test`。

`lib/rwkv_model.dart` 管理权重下载、导入、校验和重打包，`lib/rwkv_forecast.dart` 处理特征及结果投影，`lib/rwkv_native.dart` 通过 FFI 调用 `native/rwkv_minute.cpp`。`hook/build.dart` 构建本地运行库，`lib/rwkv_forecast_panel.dart` 提供预测界面。`lib/market_service.dart` 负责行情请求，`lib/history_chart.dart` 绘制日线历史曲线。
