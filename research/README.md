# 金融走势模型评估

同事提供的 RWKV7 A 股分钟模型已完成 Mac CPU 适配原型试跑，详见 [RWKV7 分钟预测接入核查](RWKV7.md)。它预测未来 1～30 分钟，需要独立分钟数据，尚未接入 App，也未完成与官方 CUDA 输出的数值对齐，不加入下述日线比较表。

这里是离线研究工具，不是行情后端，也不提供模型HTTP服务。Kronos与Chronos-2在运行评估的当前电脑本地通过PyTorch推理；Qwen调用现有Flutter客户端的`LlamaDeviceRuntime`，不经过Ollama。当前App模型保持Qwen，Kronos与Chronos-2尚未接入Android／Windows客户端。

已完成的本地初筛见 [2026-11-03实测报告](../docs/financial-model-evaluation-2026-11-03.md)，包含逐条结果与环境版本。

更大模型的追加比较见 [2026-11-04 Kronos-base报告](../docs/financial-model-evaluation-2026-11-04.md)：base在本轮相同样本上未显示整体优势，暂不替换App模型。

Amazon通用时间序列模型见 [2026-11-04 Chronos-2报告](../docs/financial-model-evaluation-2026-11-04-chronos.md)：两种历史输入方案已本地实测，中长期误差小于Kronos，但仍未超过价格不变基线。

## 比较方案

- 固定股票池：贵州茅台、平安银行、招商银行。它们只是验证流程的小样本，不代表整个A股。
- 固定预测周期：5、20、60个交易日；固定历史窗口61根，与当前App可用历史长度一致。
- 每只股票3个时点，时点间隔60根真实日线，未来标签不重叠。同一天不同股票仍有关联，各周期也不能当成独立样本。
- 基线：价格不变（收益率为0）；近20日对数价格趋势外推。
- Kronos-mini／small／base：原始预训练权重，每时点3次采样取均值，`T=1.0`、`top_p=0.9`，种子42加样本序号，CPU最多4线程。默认运行mini与small；base约102.3M参数，可通过`--models`显式选择。
- Chronos-2：约120M参数，固定2025-10-30首发权重与`chronos-forecasting==2.2.2`，float32、CPU最多4线程，使用0.5分位数作为点预测。预先固定两种输入：`Chronos-2-close`只输入61根收盘价；`Chronos-2-ohlcv`额外输入同一历史区间的开高低价、成交量和成交额。后者是过去协变量，不提供未来协变量。每个时点单独推理，关闭跨任务学习，不把不同历史时点放在同一组。
- Qwen：现有端侧Qwen2.5-0.5B Q4_K_M、原提示词、`temp=0`、种子42。一次调用生成三个期末目标，不使用服务端模型或另写提示词。
- Kronos输入包含OHLC、成交量、成交额；Qwen沿用收盘价与技术统计量。因此比较的是实际方案，不是严格控制特征及点预测统计量后的架构对比。Kronos使用采样均值，Chronos使用中位数；不能直接将MAE结果等同架构优劣。
- 以实际第5／20／60根后续日线计算价格收益；所有模型都不能读取未来价格。Kronos时间特征只用从预测时点推算的工作日，未接入交易所节假日和停牌日历。
- 衡量收益率MAE／RMSE（单位：百分点）、方向命中率、失败数和耗时。不生成“已校准概率”，不将预测精度等同交易利润。

Kronos输入的“tokenizer”也是一个神经网络，随各模型分别加载。代码及权重版本固定在`model_pins.json`，模型来自[官方仓库](https://github.com/shiyu-coder/Kronos)和[NeoQuasar模型仓库](https://huggingface.co/NeoQuasar)。时点要求晚于这些固定权重2025-09-09的公开版本，但无法完全审计预训练数据；这轮不能宣称彻底排除全部数据污染。

Chronos来自[Amazon官方模型仓库](https://huggingface.co/amazon/chronos-2)，采用Apache-2.0许可。选中Chronos时会额外检查时点晚于2025-10-30固定权重的发布；不采用后续仅更新说明文档的最新分支标识替代版本固定。该模型是通用时间序列模型，未因官方通用榜单成绩而假定它具备股票预测优势；本轮不校准其概率区间。

数据使用AKShare新浪接口的不复权OHLCV／成交额，下载后校验并保存SHA-256。日线只采用北京时间完整交易日；缺失数据直接失败，不补造行情。不复权与当前App口径一致，但分红、拆股会影响价格收益，因此结果不是含分红的总收益；下一阶段应增加复权／公司行动敏感性分析。

## 安装（独立研究环境）

在仓库根目录执行，推荐Python 3.13；不修改`backend/.venv`：

```sh
python3.13 -m venv research/.venv
research/.venv/bin/python -m pip install -r research/requirements.txt
git clone https://github.com/shiyu-coder/Kronos.git research/runtime/Kronos
git -C research/runtime/Kronos checkout 67b630e67f6a18c9e9be918d9b4337c960db1e9a
```

Windows使用`py -3.13 -m venv research/.venv`，后续将Python路径改为`research/.venv/Scripts/python.exe`。这只是在Windows本机做研究评估，不是将模型部署为后端。Windows版Flutter需先安装其桌面构建工具。

首次运行需要联网下载选定的Kronos模型及各自的tokenizer；Hugging Face缓存保存在用户缓存目录。base与small共用Kronos-Tokenizer-base，base的浮点权重约409 MB。权重和原始行情不提交Git。已有缓存后可用`HF_HUB_OFFLINE=1`，验证推理不依赖模型服务。

Chronos-2的浮点权重约478 MB，直接在当前电脑加载，不需要AWS账号或云服务。若下载卡在Xet组件，可设置`HF_HUB_DISABLE_XET=1`使用普通HTTP下载。首次安装研究依赖会升级研究环境中的Hugging Face库，不修改行情后端或Flutter依赖；各轮结果保留当时环境版本。

## 运行

```sh
# 冻结行情，不覆盖已有数据；需要更新时另指定--output路径
research/.venv/bin/python research/prepare_data.py --end 2026-11-02

# 同时比较Kronos、两个基线和当前端侧Qwen
research/.venv/bin/python research/evaluate.py \
  --output research/runtime/eval-example \
  --qwen-model /完整路径/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  --flutter /完整路径/flutter

# 如暂时不比较Qwen，可以省略--qwen-model及--flutter
research/.venv/bin/python research/evaluate.py --output research/runtime/kronos-only

# 加入更大的base，沿用上一轮冻结行情和全部评估参数
research/.venv/bin/python research/evaluate.py \
  --dataset research/runtime/eval-2026-11-03-final/dataset.json \
  --models Kronos-mini Kronos-small Kronos-base \
  --output research/runtime/eval-2026-11-04-base

# 同一批冻结数据，对比Chronos两种输入与Kronos
research/.venv/bin/python research/evaluate.py \
  --dataset research/runtime/eval-2026-11-03-final/dataset.json \
  --models Kronos-mini Kronos-small Kronos-base Chronos-2-close Chronos-2-ohlcv \
  --output research/runtime/eval-2026-11-04-chronos
```

输出目录必须是新目录，避免不同实验互相覆盖。数据不足、模型版本不符会报错。每个模型失败的样本保留错误，不以基线替代；报告仅在所有指定模型均成功的共同样本上计算主表，另列失败数。脚本异常中断时保存的部分报告不代表完成。

输出包含`REPORT.md`、`results.json`、冻结行情副本、Qwen输入／逐条原始输出和日志。`results.json`记录每条预测、实际收益、输入指纹、参数和固定模型版本。Qwen输入文件仅包含历史数据，不含未来标签。

Qwen耗时包含每次加载模型，Kronos与Chronos在内存中预先加载；耗时不能直接作为Qwen与其他引擎的性能排名，更不能外推到Android手机。后续端侧部署还需要原生运行库适配、量化和设备实测，现有Qwen的GGUF入口不能导入Kronos或Chronos权重。

## 校验

```sh
research/.venv/bin/python -m unittest discover -s research -v
cd flutter_prediction
flutter analyze
flutter test
```

常规测试不下载或运行真实模型，批量Qwen测试只有显式设置三个`DEVICE_*`路径时才执行。Python测试覆盖滚动切片、未来信息隔离、指标口径、错误样本对齐、数据篡改拒绝，以及Chronos历史协变量、发布时点、中位数选择与输出形状检查。

扩大研究前，应先固定更广股票池和新时段，再检验多个种子、不同市场阶段、复权收益和费用；不要根据这次测试的结果反复调参后仍将它称为独立测试集。
