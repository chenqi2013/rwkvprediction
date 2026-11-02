import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'device_forecast.dart';
import 'device_model.dart';
import 'models.dart';

class DeviceModelPage extends StatefulWidget {
  const DeviceModelPage({super.key, required this.model, this.onRefresh});
  final DeviceModel model;
  final Future<void> Function()? onRefresh;

  @override
  State<DeviceModelPage> createState() => _DeviceModelPageState();
}

class _DeviceModelPageState extends State<DeviceModelPage>
    with WidgetsBindingObserver {
  MarketSnapshot? result;
  String? error;
  bool testing = false;
  DeviceModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    perform(model.initialize);
  }

  Future<void> perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (testing) model.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (testing) model.cancel();
    super.dispose();
  }

  Future<void> importModel() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Qwen GGUF', extensions: ['gguf']),
      ],
    );
    if (file != null && mounted) await model.importStream(file.openRead());
  }

  Future<void> downloadInBrowser() async {
    if (!await launchUrl(
      Uri.parse(deviceModelUrl),
      mode: LaunchMode.externalApplication,
    )) {
      throw const FormatException('无法打开浏览器，请稍后重试');
    }
  }

  Future<void> testModel() async {
    setState(() {
      testing = true;
      error = null;
      result = null;
    });
    try {
      final fixture = Json.from(
        jsonDecode(await rootBundle.loadString('assets/market-demo.json')),
      );
      final quote = Json.from(fixture['snapshots']['510300'])
        ..remove('predictions')
        ..['source'] = 'mock';
      final response = MarketSnapshot(await model.predict(quote));
      if (mounted) setState(() => result = response);
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('端侧模型')),
    body: ListenableBuilder(
      listenable: model,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            deviceModelName,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          const Text(
            '模型在本设备内通过 llama.cpp 运行，使用 CPU 推理。首次下载约 469 MiB，'
            '也可导入指定的 GGUF 文件。安装完成后，离线试跑不需要联网或启动电脑服务。',
          ),
          const SizedBox(height: 12),
          SelectableText(deviceModelFilename),
          const SizedBox(height: 20),
          Text(model.status, key: const ValueKey('device-model-status')),
          if (model.busy) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: model.progress),
            if (model.progress != null)
              Text('${(model.progress! * 100).toStringAsFixed(1)}%'),
          ],
          if (error ?? model.error case final String message) ...[
            const SizedBox(height: 12),
            SelectableText(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: model.busy || model.ready
                    ? null
                    : () => perform(model.download),
                icon: const Icon(Icons.download_outlined),
                label: const Text('下载模型'),
              ),
              OutlinedButton.icon(
                onPressed: model.busy ? null : () => perform(downloadInBrowser),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('浏览器下载'),
              ),
              OutlinedButton.icon(
                onPressed: model.busy ? null : () => perform(importModel),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('导入 GGUF'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('浏览器下载完成后，点击「导入 GGUF」选择模型文件。'),
          const SizedBox(height: 28),
          const Text(
            '离线试跑',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          const Text(
            '使用内置沪深300ETF样例收盘价，实际调用本设备模型生成 5／20／60 日目标与解读。'
            '样例行情不代表当前市场；模型尚未回测，结果仅用于验证接入效果。',
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            key: const ValueKey('device-model-test'),
            onPressed: model.ready && !model.busy ? testModel : null,
            child: Text(testing ? '正在本设备推理…' : '使用样例行情试跑'),
          ),
          if (testing)
            TextButton(onPressed: model.cancel, child: const Text('取消推理')),
          if (result case final snapshot?) ...[
            const SizedBox(height: 16),
            for (final forecast in snapshot.predictions.values)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${forecast.horizon} 个交易日 · '
                        '期末中位价 ${forecast.last.median.toStringAsFixed(3)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(forecast.explanation),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              '本设备实测：输入 ${snapshot.predictions[5]!.usage['input_tokens']} Token，'
              '输出 ${snapshot.predictions[5]!.usage['output_tokens']} Token，'
              '${snapshot.predictions[5]!.usage['latency_ms']} ms（包含模型加载）。'
              '三个周期共用一次推理。',
            ),
          ],
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: model.ready && !model.busy && widget.onRefresh != null
                ? () {
                    widget.onRefresh!();
                    Navigator.pop(context);
                  }
                : null,
            child: const Text('获取真实行情并在本设备预测'),
          ),
          const SizedBox(height: 8),
          const Text('真实行情的获取仍使用设置中的行情服务地址；行情服务不运行模型。'),
        ],
      ),
    ),
  );
}
