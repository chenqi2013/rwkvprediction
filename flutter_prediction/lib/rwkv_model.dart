import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'minute_models.dart';
import 'model_download_client.dart';
import 'rwkv_forecast.dart';
import 'rwkv_native.dart';

const rwkvRevision = '26fb7031ebb4092329bb79ce3d422283d7a14e3b';
const rwkvRepo = 'Caizus/rwkv7-ashare-1min-quantile-21m';

Future<String> _hashFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// Only the six immutable, SHA256-verified safetensors files are accepted.
/// Repacking preserves every BF16 bit; no remote Python/model code is executed.
Future<String> packRwkvModel(String directory, Map<String, String> pins) async {
  final tensors = <String, (List<int>, Uint8List)>{};
  for (final entry in pins.entries) {
    if (!RegExp(
      r'^model-0000[1-6]-of-00006\.safetensors$',
    ).hasMatch(entry.key)) {
      throw const FormatException('模型清单包含非法文件名');
    }
    final file = File('$directory/${entry.key}');
    if (!await file.exists() || await _hashFile(file) != entry.value) {
      throw FormatException('模型文件校验失败：${entry.key}');
    }
    final raw = await file.readAsBytes();
    final length = ByteData.sublistView(raw).getUint64(0, Endian.little);
    if (length > raw.length - 8) throw const FormatException('模型头无效');
    final header = jsonDecode(utf8.decode(raw.sublist(8, 8 + length))) as Map;
    for (final item in header.entries) {
      if (item.key == '__metadata__') continue;
      final value = item.value as Map;
      final shape = List<int>.from(value['shape']);
      final offsets = List<int>.from(value['data_offsets']);
      final elements = shape.fold<int>(1, (a, b) => a * b);
      if (value['dtype'] != 'BF16' ||
          offsets.length != 2 ||
          offsets[0] < 0 ||
          offsets[1] < offsets[0] ||
          8 + length + offsets[1] > raw.length ||
          offsets[1] - offsets[0] != elements * 2 ||
          tensors.containsKey(item.key)) {
        throw const FormatException('模型张量无效');
      }
      tensors[item.key as String] = (
        shape,
        Uint8List.sublistView(
          raw,
          8 + length + offsets[0],
          8 + length + offsets[1],
        ),
      );
    }
  }
  if (tensors.length != 799 ||
      tensors.values.fold<int>(0, (n, v) => n + v.$2.length ~/ 2) != 21017148) {
    throw const FormatException('模型张量数量不匹配');
  }
  final temporary = File('$directory/rwkv21m.bin.part');
  final sink = temporary.openWrite();
  Uint8List integer(int n) =>
      (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
  try {
    sink.add(ascii.encode('RWKV21M1'));
    sink.add(integer(tensors.length));
    for (final name in tensors.keys.toList()..sort()) {
      final bytes = utf8.encode(name);
      final (shape, data) = tensors[name]!;
      sink.add(integer(bytes.length));
      sink.add(bytes);
      sink.add(integer(shape.length));
      for (final dim in shape) {
        sink.add(integer(dim));
      }
      sink.add(data);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  final target = File('$directory/rwkv21m.bin');
  // Windows rename does not replace an existing destination.
  if (await target.exists()) await target.delete();
  await temporary.rename(target.path);
  return _hashFile(target);
}

class RwkvModel extends ChangeNotifier {
  RwkvModel({Directory? directory}) : _directory = directory;
  static bool _licensesRegistered = false;
  Directory? _directory;
  Map<String, String>? _pins;
  String? _packedHash;
  Future<void>? _initialization;
  http.Client? _client;
  bool _disposed = false;
  bool ready = false;
  bool busy = false;
  double? progress;
  String status = '尚未安装 RWKV 分钟模型（约 40 MiB）';
  String? error;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      if (!_licensesRegistered) {
        _licensesRegistered = true;
        LicenseRegistry.addLicense(() async* {
          yield LicenseEntryWithLineBreaks(
            ['RWKV7 minute forecast'],
            '${await rootBundle.loadString('native/THIRD_PARTY_NOTICES.md')}\n\n${await rootBundle.loadString('native/LICENSE-APACHE-2.0')}',
          );
        });
      }
      _directory ??= Directory(
        '${(await getApplicationSupportDirectory()).path}/models/rwkv7-ashare-21m',
      );
      await _directory!.create(recursive: true);
      final manifest =
          jsonDecode(await rootBundle.loadString('assets/rwkv/manifest.json'))
              as Map;
      if (manifest['repo'] != rwkvRepo ||
          manifest['revision'] != rwkvRevision) {
        throw const FormatException('RWKV 模型版本不匹配');
      }
      _pins = Map<String, String>.from(manifest['sha256'])
        ..removeWhere((name, _) => !name.endsWith('.safetensors'));
      if (await Future.wait(
        _pins!.keys.map((n) => File('${_directory!.path}/$n').exists()),
      ).then((v) => v.every((v) => v))) {
        status = '正在校验 RWKV 模型';
        changed();
        await _pack();
      }
    } catch (e) {
      error = '$e';
      status = 'RWKV 模型未就绪，请重新下载或导入';
    }
    changed();
  }

  Future<void> _pack() async {
    final directory = _directory!.path;
    final pins = _pins!;
    _packedHash = await Isolate.run(() => packRwkvModel(directory, pins));
    ready = true;
    status = 'RWKV7 · 21M · 本设备 CPU · 实验版';
  }

  Future<void> install({String? sourceDirectory}) async {
    await initialize();
    if (busy || _disposed) return;
    busy = true;
    error = null;
    progress = 0;
    ready = false;
    changed();
    http.Client? client;
    try {
      if (_pins == null || _directory == null) {
        throw const FormatException('模型目录初始化失败，请重新打开分钟行情页面');
      }
      client = sourceDirectory == null
          ? await createModelDownloadClient()
          : null;
      _client = client;
      var finished = 0;
      for (final entry in _pins!.entries) {
        if (_disposed) return;
        final target = File('${_directory!.path}/${entry.key}');
        if (await target.exists() && await _hashFile(target) == entry.value) {
          ++finished;
          continue;
        }
        status =
            '${sourceDirectory == null ? '下载' : '导入'} RWKV 模型 ${finished + 1}/6';
        changed();
        final temporary = File('${target.path}.part');
        try {
          if (sourceDirectory != null) {
            await File('$sourceDirectory/${entry.key}').copy(temporary.path);
          } else {
            final response = await client!
                .send(
                  http.Request(
                    'GET',
                    Uri.parse(
                      'https://huggingface.co/$rwkvRepo/resolve/$rwkvRevision/${entry.key}',
                    ),
                  ),
                )
                .timeout(const Duration(seconds: 45));
            if (response.statusCode != 200) {
              throw HttpException('模型下载 HTTP ${response.statusCode}');
            }
            final sink = temporary.openWrite();
            var received = 0;
            try {
              await for (final chunk in response.stream.timeout(
                const Duration(seconds: 45),
              )) {
                received += chunk.length;
                if (received > 43000000) {
                  throw const FormatException('模型文件大小异常');
                }
                sink.add(chunk);
                progress =
                    ((finished +
                                (response.contentLength == null
                                    ? 0
                                    : received / response.contentLength!)) /
                            6)
                        .clamp(0, 1);
                changed();
              }
              await sink.flush();
            } finally {
              await sink.close();
            }
          }
          if (await _hashFile(temporary) != entry.value) {
            throw FormatException('模型 SHA256 校验失败：${entry.key}');
          }
          if (await target.exists()) await target.delete();
          await temporary.rename(target.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
        ++finished;
        progress = finished / 6;
        changed();
      }
      status = '校验并准备端侧权重';
      changed();
      await _pack();
    } catch (e) {
      error = '$e';
      status = '模型安装失败，可重试';
    } finally {
      client?.close();
      _client = null;
      busy = false;
      changed();
    }
  }

  Future<RwkvForecast> predict(MinuteSnapshot snapshot, String origin) async {
    await initialize();
    if (!ready || busy || _disposed) {
      throw const FormatException('请先安装 RWKV 分钟模型');
    }
    final features = prepareRwkvFeatures(snapshot, origin);
    final inputHash = sha256.convert(features.buffer.asUint8List()).toString();
    final anchor = snapshot.bars.firstWhere((b) => b.timestamp == origin).close;
    final modelPath = '${_directory!.path}/rwkv21m.bin';
    final expectedHash = _packedHash!;
    busy = true;
    error = null;
    progress = null;
    status = '本设备 CPU 正在预测未来 30 分钟';
    changed();
    try {
      final result = await Isolate.run(() async {
        if (await _hashFile(File(modelPath)) != expectedHash) {
          throw const FormatException('端侧权重已变化，请重新安装');
        }
        final watch = Stopwatch()..start();
        final output = nativeMinuteForecast(modelPath, features);
        return (output.toList(), watch.elapsedMilliseconds);
      });
      final forecast = RwkvForecast(
        instrumentId: snapshot.instrument.id,
        origin: origin,
        anchor: anchor,
        raw: result.$1,
        latencyMs: result.$2,
        inputHash: inputHash,
        universeId: snapshot.market!['universe_id'] as String,
      );
      forecast
          .prices; // Validate decoded output before displaying any prediction.
      return forecast;
    } catch (e) {
      error = '$e';
      rethrow;
    } finally {
      busy = false;
      status = 'RWKV7 · 21M · 本设备 CPU · 实验版';
      changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _client?.close();
    super.dispose();
  }
}
