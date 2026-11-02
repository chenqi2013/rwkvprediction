# 端侧模型实验

Flutter 客户端通过 Dart FFI 调用 llama.cpp，在当前设备进程内运行 **Qwen2.5-0.5B-Instruct Q4_K_M**。Android 手机上就在手机运行，Windows 上就在 Windows 电脑运行，不调用 Ollama 或远端模型 API。行情后端只为新客户端提供报价和历史日线。

## 使用

1. 运行 Flutter 客户端，打开「设置 → 端侧模型」，也可从首页错误页进入。
2. 下载约 **469 MiB** 的模型，或导入 `qwen2.5-0.5b-instruct-q4_k_m.gguf`。客户端核对完整文件大小和 SHA-256，失败不安装；权重存入设备应用支持目录的 `models/`，不提交到 Git，也不随 APK 分发。下载失败可以重试或导入，目前不支持断点续传。
3. 点击「使用样例行情试跑」：输入来自内置沪深300ETF样例，预测实际由本设备模型生成。安装模型后此操作完全离线，展示三个周期解读、实测 Token 和包含模型加载的耗时。
4. 要获取真实行情，在设置中填写行情 API 地址，然后点击「获取真实行情并在本设备预测」。目前行情获取仍依赖 Python／AKShare 服务；该服务可独立部署，不承担模型推理。没有行情服务时仍能离线试跑。

模型固定为官方 [Qwen GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF)，提交 `9217f5db79a29953eb74d5343926648285ec7e67`，文件大小 `491400032` 字节，SHA-256：

```text
74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db
```

该导入入口只接受指定模型，不能导入任意 GGUF。运行需要额外内存，文件大小不等于推理内存；低内存设备可能加载失败。当前 CPU 最多使用 4 线程、上下文 2048 Token；每次运行结束释放引擎，切换标的、取消或应用进入后台会取消当前生成。推理失败明确报错，不使用模拟预测替代。

## 数据和结果的来源

- 输入：最近 2–61 个完整交易日收盘价，提示词包含最近 20 根收盘价、近 5／20 日涨跌、均线和日对数收益波动率。
- 模型生成：未来 5／20／60 日的期末目标收益率与简短中文解读。JSON 语法受约束，收益率和解读长度另经客户端校验。
- 客户端计算：按目标对数插值中位路径，按历史日对数收益波动率乘时间平方根估算区间；上涨概率采用对数正态假设。这些都是未经校准的统计估算，情景 20%／60%／20% 是展示设定。
- 用量：引擎返回实测 Token；耗时包含模型加载和本设备推理，不含行情网络请求。三个周期共用一次推理，不能累加三份用量。
- 回测：尚未开展，`backtest.status=not_evaluated`，页面显示 `—`。小型通用语言模型不代表具备金融预测能力。
- 保存：`source/forecast_source=on_device`，`usage.execution=on_device`；下发按钮生成 `saved_locally` 回执，只存当前客户端，不向服务器上传模型输出。Webhook 仍为演示，不发送外部通知。
- 日期：未来日期仅跳过周末，尚未对齐交易所节假日。

## 后端边界

Flutter 使用 `GET /v1/markets/{id}?inference=device`。该请求即使后端另配推理引擎，也只返回行情，剔除 `predictions`，不调用后端模型或保存预测。`/health` 是行情进程状态，不反映设备模型是否安装或能运行。

`backend/forecast_config.json` 现在使用 `{"provider":"mock"}`，不再启用之前的服务端 Qwen 试验。修改后重启已有服务：

```sh
launchctl kickstart -k gui/$(id -u)/com.rwkvprediction.market-api
```

原生 SwiftUI 原型仍走旧接口，默认显示真实行情加模拟预测，尚未接入端侧引擎。旧服务端 `forecast_engine.py` 及其可选配置保留供兼容实验使用；Flutter 新路径不依赖它，也不需要启动或安装 Ollama。不要把旧服务端试验的性能记录当作手机端性能。

## Android、Windows 与构建

当前使用 `llamadart 0.17.4`，选择 llama.cpp 运行库，推理参数固定使用 CPU。Android 最低 9（API 28，与预编译推理库一致），使用 arm64-v8a 或 x86_64（不支持 32 位 ARM）；Windows 原生库覆盖 x64／arm64，实际应用需在相应系统构建和验证。Windows 应分发完整构建目录，包含 DLL 和 Flutter assets，不能只复制 EXE。

```sh
cd flutter_prediction
flutter pub get
flutter build apk --debug --target-platform android-arm64,android-x64
# 在 Windows 上执行
flutter build windows --release
```

Apple 平台按依赖要求使用 iOS 16.4+／macOS 14+。当前使用 build hook 打包本地库；Apple 商店分发需另行核对上游 companion／SwiftPM 的隐私清单与打包要求。

## 校验与后续 RWKV

常规测试不下载权重。可选真实模型测试在 Flutter 测试进程中直接加载本地 GGUF，不调用模型服务：

```sh
flutter test
flutter test test/device_runtime_smoke_test.dart --dart-define=DEVICE_MODEL_PATH=/完整路径/qwen2.5-0.5b-instruct-q4_k_m.gguf
```

`lib/device_model.dart` 的 `ForecastRuntime.generate(path, quote)`／`cancel()` 隔离推理实现；`device_forecast.dart` 处理输入、校验和展示投影。后续 RWKV 需要接入其本地原生运行库，实现该接口并更换模型安装与校验信息；不是改后端地址即可，也不保证 Qwen GGUF 可以用于 RWKV。

2026-11-02 在当前 Apple Silicon Mac 上，Flutter 测试进程内加载 GGUF 并使用 CPU 验证通过：样例行情输入 739／输出 126 Token，约 5.2 秒；真实 AKShare 日线输入 717／输出 108 Token，约 4.9 秒，均包含模型加载。macOS App 内导入及样例试跑也已验证。Android APK 构建通过，Android 真机及 Windows 运行由另一台设备验证；上述耗时不代表它们的性能。真实输入响应保存在本机忽略目录 `backend/runtime/qwen-on-device-smoke.json`。
