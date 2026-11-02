import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

import 'device_forecast.dart';
import 'models.dart';

const deviceModelFilename = 'qwen2.5-0.5b-instruct-q4_k_m.gguf';
const deviceModelBytes = 491400032;
const deviceModelSha256 =
    '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db';
const deviceModelUrl =
    'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/'
    '9217f5db79a29953eb74d5343926648285ec7e67/$deviceModelFilename';

abstract class ForecastRuntime {
  Future<Json> generate(String path, Json quote);
  void cancel();
}

class LlamaDeviceRuntime implements ForecastRuntime {
  LlamaEngine? _engine;
  int _generation = 0;

  @override
  void cancel() {
    ++_generation;
    _engine?.cancelGeneration();
  }

  @override
  Future<Json> generate(String path, Json quote) async {
    final revision = ++_generation;
    final watch = Stopwatch()..start();
    final input = deviceForecastInput(quote);
    LlamaEngine? engine;
    Timer? timeout;
    var timedOut = false;
    try {
      engine = await LlamaEngine.load(
        LlamaModel(ModelSource.path(path)),
        params: ModelParams(
          contextSize: 2048,
          gpuLayers: 0,
          device: ComputeDevice.cpu,
          numberOfThreads: Platform.numberOfProcessors.clamp(1, 4),
          batchSize: 256,
          microBatchSize: 128,
        ),
      );
      _engine = engine;
      if (revision != _generation) throw const FormatException('推理已取消');
      timeout = Timer(const Duration(minutes: 3), () {
        timedOut = true;
        engine?.cancelGeneration();
      });
      final result = await engine
          .create(
            [
              const LlamaChatMessage.fromText(
                role: LlamaChatRole.system,
                text: deviceForecastSystem,
              ),
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: input),
            ],
            params: const GenerationParams(maxTokens: 600, temp: 0, seed: 42),
            enableThinking: false,
            responseFormat: {
              'type': 'json_schema',
              'json_schema': {
                'name': 'forecast',
                'strict': true,
                'schema': deviceForecastSchema(),
              },
            },
          )
          .collect();
      if (timedOut) throw const FormatException('端侧推理超时，可在性能更好的设备上重试');
      if (revision != _generation) throw const FormatException('推理已取消');
      if (result.finishReason != LlamaFinishReason.stop) {
        throw const FormatException('模型输出未完整结束');
      }
      final measured = result.usage;
      if (measured == null) throw const FormatException('推理引擎未返回实测 Token 用量');
      return projectDeviceForecast(quote, parseDeviceEstimates(result.text), {
        'input_tokens': measured.promptTokens,
        'output_tokens': measured.completionTokens,
        'latency_ms': watch.elapsedMilliseconds,
        'runtime': 'llama.cpp · CPU',
        'includes_model_load': true,
      });
    } finally {
      timeout?.cancel();
      _engine = null;
      await engine?.dispose();
    }
  }
}

Future<bool> verifyDeviceModel(String path) async {
  final file = File(path);
  if (!await file.exists() || await file.length() != deviceModelBytes) {
    return false;
  }
  return (await sha256.bind(file.openRead()).first).toString() ==
      deviceModelSha256;
}

class DeviceModel extends ChangeNotifier {
  DeviceModel({Directory? directory, ForecastRuntime? runtime})
    : _directory = directory,
      _runtime = runtime ?? LlamaDeviceRuntime();
  Directory? _directory;
  final ForecastRuntime _runtime;
  Future<void>? _initialization;
  Future<Json>? _inference;
  http.Client? _downloadClient;
  bool ready = false;
  bool busy = false;
  bool disposed = false;
  double? progress;
  String status = '尚未下载模型';
  String? error;
  String? modelPath;

  void _changed() {
    if (!disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    _directory ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/models',
    );
    await _directory!.create(recursive: true);
    modelPath = '${_directory!.path}/$deviceModelFilename';
    if (await File(modelPath!).exists()) {
      status = '正在校验模型';
      _changed();
      final path = modelPath!;
      ready = await Isolate.run(() => verifyDeviceModel(path));
      status = ready ? '模型已就绪 · 本设备 CPU 推理' : '模型校验失败，请重新下载或导入';
    }
    _changed();
  }

  Future<void> download() async {
    await initialize();
    if (busy || disposed) return;
    busy = true;
    error = null;
    progress = 0;
    status = '正在下载模型（约 469 MiB）';
    _changed();
    final client = http.Client();
    _downloadClient = client;
    final temporary = File('$modelPath.part');
    IOSink? sink;
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(deviceModelUrl)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('模型下载返回 HTTP ${response.statusCode}');
      }
      sink = temporary.openWrite();
      var received = 0;
      var lastUpdate = DateTime.now();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        if (disposed) throw const HttpException('下载已取消');
        received += chunk.length;
        if (received > deviceModelBytes) {
          throw const FormatException('模型文件大小不符');
        }
        sink.add(chunk);
        if (DateTime.now().difference(lastUpdate).inMilliseconds >= 200) {
          progress = received / deviceModelBytes;
          lastUpdate = DateTime.now();
          _changed();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await _install(temporary);
    } catch (exception) {
      error = exception.toString();
      status = '下载未完成，可重试或导入模型文件';
    } finally {
      await sink?.close();
      client.close();
      _downloadClient = null;
      if (await temporary.exists()) await temporary.delete();
      busy = false;
      progress = null;
      _changed();
    }
  }

  Future<void> importStream(Stream<List<int>> bytes) async {
    await initialize();
    if (busy || disposed) return;
    busy = true;
    error = null;
    status = '正在导入并校验模型';
    _changed();
    final temporary = File('$modelPath.part');
    IOSink? sink;
    try {
      sink = temporary.openWrite();
      var received = 0;
      await for (final chunk in bytes) {
        if (disposed) throw const FormatException('导入已取消');
        received += chunk.length;
        if (received > deviceModelBytes) {
          throw const FormatException('模型文件大小不符');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await _install(temporary);
    } catch (exception) {
      error = exception.toString();
      status = '导入失败，请选择指定的 Qwen GGUF 文件';
    } finally {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      busy = false;
      _changed();
    }
  }

  Future<void> _install(File temporary) async {
    status = '正在校验模型 SHA-256';
    _changed();
    final path = temporary.path;
    if (!await Isolate.run(() => verifyDeviceModel(path))) {
      throw const FormatException('模型文件大小或 SHA-256 不符，未安装');
    }
    if (disposed) throw const FormatException('模型操作已取消');
    final destination = File(modelPath!);
    if (await destination.exists()) await destination.delete();
    await temporary.rename(modelPath!);
    ready = true;
    status = '模型已就绪 · 本设备 CPU 推理';
  }

  Future<Json> predict(Json quote) async {
    await initialize();
    if (!ready) throw const FormatException('请先在设置 → 端侧模型中下载或导入 Qwen 模型');
    if (busy || disposed) throw const FormatException('端侧模型忙，请稍后重试');
    busy = true;
    status = '正在本设备推理…';
    error = null;
    _changed();
    try {
      final task = _runtime.generate(modelPath!, quote);
      _inference = task;
      return await task;
    } catch (exception) {
      error = exception.toString();
      rethrow;
    } finally {
      _inference = null;
      busy = false;
      status = '模型已就绪 · 本设备 CPU 推理';
      _changed();
    }
  }

  void cancel() => _runtime.cancel();

  Future<void> cancelAndWait() async {
    cancel();
    try {
      await _inference;
    } catch (_) {}
  }

  @override
  void dispose() {
    disposed = true;
    _downloadClient?.close();
    cancel();
    super.dispose();
  }
}
