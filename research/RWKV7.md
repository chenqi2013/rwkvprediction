# RWKV7 分钟预测接入核查（2026-11-09）

已核对 [Caizus/rwkv7-ashare-1min-quantile-21m](https://huggingface.co/Caizus/rwkv7-ashare-1min-quantile-21m)，并在当前 Mac 上完成真实权重的本地 CPU 适配试跑。后续已将独立 C++ CPU 实现通过 Dart FFI 接入 Flutter 的分钟预测实验功能，见 [端侧使用说明](../flutter_prediction/RWKV_MINUTE.md)。Qwen 日线预测与分钟预测分别运行，没有新增模型后端服务。

后续已新增 Flutter 分钟行情页面、真实分钟接口与固定实验股票集合统计，见 [分钟行情文档](../backend/MINUTE_MARKET.md)。研究脚本可直接读取该接口响应或单次请求导出 JSON。App 原生 CPU 实现已与研究原型比较；官方 CUDA 数值与训练统计集合仍待核对。下文中的原始接入方案保留为研究记录。

## 模型与现有功能的区别

| 项目 | 此 RWKV 模型 | 当前 App |
|---|---|---|
| 任务 | A 股未来 1～30 分钟收盘价分位数 | 未来 5／20／60 个交易日期末收益实验 |
| 输入 | 最近 64 根已编码分钟 bar，每根 23 个特征 | 最多 61 根日线及统计量 |
| 原始数据 | 至少 65 根连续分钟 OHLCV，完整连续时段前缀与同期市场统计 | 行情接口目前只返回日线历史收盘价、成交量 |
| 输出 | `[batch,30,9]`，q0.1～q0.9 | Qwen JSON 目标收益与文字解读 |
| 权重 | 21,017,102 参数，6 个 BF16 safetensors 分片，共 42,112,872 字节（约 40.2 MiB） | Qwen GGUF，约 469 MiB |
| 官方运行依赖 | 指定 Transformers-RWKV 分支、FlashRWKV2、TileLang、Linux + NVIDIA CUDA | llama.cpp 端侧 CPU |

发布包的 `RWKV7ForQuantileForecasting` 是数值特征投影 + RWKV7 主干 + 分位数输出头，没有聊天 tokenizer／文本生成流程。现有 GGUF 导入入口、普通 RWKV 聊天运行库均不能直接替换加载它。其固定主干源码还明确拒绝 `torch.compile`／export，不能直接对原模型调用 ONNX 导出。

模型固定 revision 为 `26fb7031ebb4092329bb79ce3d422283d7a14e3b`，主干固定 revision 为 `f93dd4e01e0b565ef0390f76c6726d1d121ebbab`。下载文件 SHA256 记录于 `rwkv7_pins.json`，六个权重分片与作者 `verification.json` 一致；只加载 safetensors，不执行仓库远程代码。

## 本次已跑通的内容

- `rwkv7_cpu.py`：用普通 PyTorch 实现特征投影、RWKV7 循环状态更新和原分位数预测头，在 CPU FP32 上模拟 BF16 边界。每次独立窗口重置状态，不需要 CUDA／Transformers fork／模型服务。
- `rwkv7_features.py`：保留并注明来源的作者预处理代码，未改动计算逻辑。CSV 输入先计算原始 23 维特征，模型内部再按权重中的训练均值、标准差归一化。
- `rwkv7_predict.py`：固定版本下载、哈希验证、CSV／NPZ 输入、输出 JSON。拒绝缺失分钟、跨午休、截断时段前缀，以及未来 30 分钟跨时段的 CSV。NPZ 没有时间来源证明，输出仅保留相对分钟步数。
- 官方合成 CSV 与 NPZ 的编码特征逐值一致，CPU 原型两条输入路径的预测结果也逐值一致。先运行另一窗口再重跑原窗口，最大输出差为 0。
- 当前 Mac、PyTorch 2.15.0、4 CPU 线程，单个合成窗口实测模型加载约 11 ms、推理约 54 ms。耗时不含文件哈希校验、行情获取、特征处理，不代表手机性能。
- 研究测试共 19 项通过，其中本次新增 7 项，覆盖输入边界、市场统计、循环状态更新与分位数价格还原。

**尚未完成与作者 CUDA 实现的数值对齐。** CPU 与 CUDA 的矩阵归约、FMA、激活计算及 BF16 舍入可能产生差异。本次仅证明在 Mac 上可运行这条适配路线，不能宣称复现了作者准确率。App 正式接入和量化前，需取得同一批真实窗口的 CUDA 原始输出并逐项比较。

## 运行方式

使用现有独立研究环境，不安装作者的 CUDA 依赖，也不修改行情后端环境：

```sh
# 首次运行下载固定版本；已下载时去掉 --download，可完全离线运行。
research/.venv/bin/python research/rwkv7_predict.py --download \
  --input research/runtime/rwkv7-ashare-21m/example_bars.csv \
  --output research/runtime/rwkv7-ashare-21m/trial-new.json

# 作者提供的同一合成样例的 NPZ 入口
research/.venv/bin/python research/rwkv7_predict.py \
  --input research/runtime/rwkv7-ashare-21m/example_inputs.npz \
  --output research/runtime/rwkv7-ashare-21m/trial-npz-new.json

research/.venv/bin/python -m unittest discover -s research -v
```

下载沿用 Hugging Face 的网络配置；当前 Mac 的代理为 `http://127.0.0.1:7890`，如终端直连失败，可按实际环境设置 `HTTPS_PROXY`。权重和试跑结果放在被 Git 忽略的 `research/runtime/`，不提交模型文件。Windows 的本机研究环境使用 `research/.venv/Scripts/python.exe`；尚未在 Windows 实机测试。本脚本不是 Android／iOS 的运行方案。

## App 接入路线

1. **先确定分钟行情与市场统计的数据契约。** 新增独立的分钟行情接口，提供上海本地时间、已完成的连续 OHLCV、数据截止时间、价格及成交量单位、固定市场股票集合标识和同分钟聚合统计。行情可以继续由后端整理，模型推理保留在端侧。成交量要核实“股／手”，不得直接沿用日线数值。市场统计要从固定股票集合的同分钟收益计算，不能用单只股票或指数涨跌代替。最好向同事取得训练集合 manifest、完整真实窗口及对应特征，核对时段首 bar 的处理和数据口径。
2. **完成 CUDA 与 CPU 对齐。** 对多股票、上午／下午、不同波动水平的同一真实历史窗口，比对特征、原始未排序 `[30,9]` 对数收益和还原价格。事先约定误差阈值；先验证 FP32／BF16 边界，再考虑 FP16 或 INT8。当前 CPU 原型不能作为已经对齐的金标准。
3. **做跨平台数值运行库。** 优先以纯数值运算图评估 ONNX Runtime 的 CPU 路线，使用循环或可复用单步图，保留输入投影、归一化和预测头；若导出／算子／性能受限，再做 C++ CPU 实现并通过 Dart FFI 接入。两条路线都需实际导出或编译验证，目前尚无可直接交付的端侧模型产物。无需在手机打包 Python，也无需部署模型 HTTP 服务。
4. **新增“分钟预测”模式。** 使用独立的分钟快照和预测数据类型，提供 5／15／30 分钟查看，显示模型中位数、60% 与 80% 区间。按实测耗时显示性能，不使用文本模型 Token 计数。图表、缓存与预测记录显式包含 `horizon_unit=minute`、模型 revision、输入指纹和数据截止时间，切换标的／后台运行时支持取消。当前图表将周期硬编码成“交易日”，并支持 95% 区间，不能直接混入此模型的输出；它没有 q0.025／q0.975，不应补造 95% 区间或上涨概率。
5. **验证真实效果与设备性能。** 在新时段比较价格不变和经验分位数基线，检查 MAE、pinball loss、区间覆盖率、偏置及数据源变化。Mac 验证完成后，分别验证 Android／Windows 的加载、内存、耗时、生命周期与结果一致性。

CSV 需从同一连续交易时段的起始 bar 提供完整前缀；滚动特征依赖更早历史，不能只取最后 65 行。上午、下午、日期、缺失分钟各自断开，不填造分钟线。历史和未来必须处于同一时段；按作者训练分布，可用起点主要在上午约 10:34～11:00、下午约 14:05～14:30，具体随数据源时间戳约定核对。临近收盘、开盘历史不足和停牌缺数据时应说明不可预测。

## 作者披露的效果

作者固定测试集为 4096 个窗口、2919 个标的、21 个日期。整段中位数 MAE 为 0.30772%，价格不变基线为 0.30599%；第 30 分钟 MAE 为 0.43640%，基线为 0.43748%。整段点预测未超过价格不变基线。分位数 pinball loss 优于作者列出的经验分位数参照，80% 区间覆盖率为 80.054%。这些是发布方报告，尚未在本项目独立复现，也不代表交易收益。

相比继续用聊天模型生成分钟数值，这个模型的输入和分位数输出更贴合任务；当前建议是作为独立的分钟预测实验接入，先解决数据口径与数值对齐，再进行 App 端侧适配。
