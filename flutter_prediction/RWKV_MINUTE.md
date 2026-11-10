# RWKV 分钟预测（端侧实验版）

模型固定为 `Caizus/rwkv7-ashare-1min-quantile-21m`，revision
`26fb7031ebb4092329bb79ce3d422283d7a14e3b`。App 使用真实的 21,017,102 个
参数和原数值预测头，提供 30×9 个累计对数收益分位数。模型不经过聊天／GGUF
运行库，也不在行情服务器或 Python 服务中推理。

## 操作

1. 顶部折线图按钮进入「分钟行情」，选择沪深 A 股股票及日期。
2. 点击「加载同期市场统计」。
3. 在「RWKV 分钟预测」下载约 40 MiB 权重，或在 Mac／Windows／Linux
   导入包含六个原始 `model-0000x-of-00006.safetensors` 的目录。
4. 选择预测起点，点击预测。收盘后默认选择当天最近一个符合条件的历史起点，
   按钮明确标记「运行历史起点预测」。

当前 Mac 已下载的原权重位于仓库忽略目录 `research/runtime/rwkv7-ashare-21m/`，
可以导入该目录。新设备首次下载权重需要访问 Hugging Face；下载失败会保留已校验
的完整分片，重试会跳过它们。Android 使用下载入口，不需要 Python 环境。

折线图展示历史与预测、预测段放大、真实价格、中位数、起点价格和两层区间。
80% 使用 q0.1～q0.9，60% 使用 q0.2～q0.8；逐分钟排序消除分位数交叉。
价格以同一真实起点收盘价乘 `exp(cumulative_log_return_x100 / 100)` 还原。
不补造 95% 区间或上涨概率。若后续分钟已返回，则显示实际匹配分钟数、价格 MAE、
维持现价 MAE 及本窗口区间覆盖率，缺失分钟不参与计算。

## 端侧实现与数据隔离

- `lib/rwkv_model.dart`：固定版本下载／目录导入、逐分片 SHA256 校验、BF16
  无损重打包。清单位于 `assets/rwkv/manifest.json`，不执行仓库远程代码。
- `lib/rwkv_forecast.dart`：完整连续时段前缀 → 原特征处理公式 → 最后 64×23
  个 FP32 特征。时间按上海本地标签计算，不受 Windows／Android 系统时区影响。
- `native/rwkv_minute.cpp`：24 层、256 隐藏维、4×64 头的 RWKV7 数值主干，
  FP32 状态及 BF16 运算边界、原预测头。每次预测重新初始化循环状态。
- `lib/rwkv_native.dart`：Dart FFI。计算在独立 isolate 中执行，UI 保持响应。
  Apple 使用系统 Accelerate；其他平台使用内置可移植 C++ CPU 矩阵运算。
  构建 hook 使用目标平台 C++ 工具链，运行时不需要 Python／Torch／CUDA。
- 模型及缓存写入 App support 的 `models/rwkv7-ashare-21m/`；推理前再次核对
  本地重打包文件指纹。行情后台仅提供数据，`forecast.status=not_run` 指后台未推理。

历史回放在特征计算前严格截断到用户选择的起点。起点之后的行情和市场统计不进入
特征；真实后续价格只用于图表和对照指标。必须从上午或下午时段起始分钟开始，
至少 65 根连续原始 bar，且未来 30 分钟不跨午休／收盘；缺失分钟不填造。
模型仅对沪深 A 股启用，ETF／指数保留行情查看。

切换起点、股票或日期会丢弃旧结果；后台返回的过期异步结果不覆盖新选择。
刷新行情后仅在输入特征指纹、标的、日期及统计集合一致时保留旧预测，让新增的
真实未来分钟用于对照。输入改变后必须重新预测。

## 验证与边界

- Dart 特征与固定原始 Python processor 的上午、下午合成窗口进行逐值比较，
  FP32 误差阈值 2e-6；另有修改未来数据不影响特征的检验。
- 原生运行库使用真实权重，与现有 PyTorch CPU 原型比较未排序的 270 个输出，
  误差阈值 0.004（100×累计对数收益单位）。重复调用验证状态重置。
- 真实茅台 2026-11-09 10:45 输入曾测得 C++ 约 39 ms（含权重加载），与
  PyTorch 原型最大差约 0.000461。该数值不是官方 CUDA 对齐或准确率证明。
- 窗口／图表／交互已覆盖手机和桌面宽度。Mac 可本机构建；Android／Windows
  构建与实机性能仍需在对应机器验证，不能据 Mac 结果承诺同样性能。

```sh
cd flutter_prediction
flutter analyze
RWKV_TEST_MODEL_DIR="$PWD/../research/runtime/rwkv7-ashare-21m" \
  flutter test
flutter build macos --debug
```

同事尚未提供训练股票全集与官方 CUDA 对照。市场统计暂使用固定 8 只实验股票，
与训练分布可能不同；CPU 原型也不是官方金标准。因此 UI 保留实验标识和数值对齐、
区间未校准说明，历史单窗口指标不代表整体预测能力或交易收益。

第三方归属和许可证见 `native/THIRD_PARTY_NOTICES.md`、
`native/LICENSE-APACHE-2.0`，也已打包进 App 的许可证注册表。
