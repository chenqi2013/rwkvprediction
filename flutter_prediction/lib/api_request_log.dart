import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class ApiRequestRecord {
  ApiRequestRecord(this.file, Json document)
    : method = document['request']['method'],
      url = document['request']['url'],
      startedAt = document['started_at'],
      statusCode = document['response']?['status_code'],
      error = document['error'];

  final File file;
  final String method;
  final String url;
  final String startedAt;
  final int? statusCode;
  final String? error;
  String get filename => file.uri.pathSegments.last;
  Uri get uri => Uri.parse(url);
  Future<String> read() => file.readAsString();
}

class ApiRequestLog extends ChangeNotifier {
  ApiRequestLog({Directory? directory}) : _directory = directory;

  Directory? _directory;
  Future<void>? _initialization;
  Future<void> _writes = Future.value();
  final List<ApiRequestRecord> _records = [];
  bool _disposed = false;
  bool initialized = false;
  int _sequence = 0;
  String? storageError;
  List<ApiRequestRecord> get records => List.unmodifiable(_records);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    try {
      _directory ??= Directory(
        '${(await getApplicationSupportDirectory()).path}/api_requests',
      );
      await _directory!.create(recursive: true);
      await for (final entity in _directory!.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final document = Json.from(jsonDecode(await entity.readAsString()));
          _records.add(ApiRequestRecord(entity, document));
        } catch (exception) {
          storageError = '部分请求记录无法读取：$exception';
        }
      }
      _records.sort(
        (first, second) => second.filename.compareTo(first.filename),
      );
    } catch (exception) {
      storageError = '请求记录目录无法读取：$exception';
    }
    initialized = true;
    _changed();
  }

  Future<void> record(Json document) {
    final text = '${const JsonEncoder.withIndent('  ').convert(document)}\n';
    final request = document['request'] as Json;
    final uri = Uri.parse(request['url']);
    final endpoint = uri.path.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final filename =
        '${stamp}_${_sequence++}_${request['method']}$endpoint.json';
    _writes = _writes.then((_) async {
      try {
        await initialize();
        if (_directory == null) throw const FileSystemException('未取得请求记录目录');
        final file = File('${_directory!.path}/$filename');
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(text, flush: true);
        await temporary.rename(file.path);
        _records.insert(0, ApiRequestRecord(file, document));
        _records.sort(
          (first, second) => second.filename.compareTo(first.filename),
        );
        storageError = null;
      } catch (exception) {
        storageError = '请求记录保存失败：$exception';
      }
      _changed();
    });
    return _writes;
  }

  Future<File> exportArchive({Directory? destination}) async {
    await initialize();
    await _writes;
    final snapshot = records;
    if (snapshot.isEmpty) throw StateError('暂无真实接口请求记录，请先加载行情或搜索标的。');
    final directory = destination ?? await getTemporaryDirectory();
    await directory.create(recursive: true);
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final file = File('${directory.path}/rwkv-api-requests-$stamp.zip');
    final encoder = ZipFileEncoder()..create(file.path);
    try {
      for (final record in snapshot.reversed) {
        await encoder.addFile(record.file, record.filename);
      }
    } finally {
      await encoder.close();
    }
    return file;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
