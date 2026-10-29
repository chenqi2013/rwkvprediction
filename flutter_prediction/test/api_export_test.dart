import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rwkv_prediction/api_export_page.dart';
import 'package:rwkv_prediction/api_request_log.dart';
import 'package:rwkv_prediction/market_controller.dart';
import 'package:rwkv_prediction/market_service.dart';
import 'package:rwkv_prediction/models.dart';
import 'package:rwkv_prediction/sheets.dart';

class TestFileActions extends ApiFileActions {
  File? saved;

  @override
  bool get canSave => true;

  @override
  Future<String?> save(File file) async {
    saved = file;
    return '/chosen/${file.uri.pathSegments.last}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ApiRequestLog log;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('rwkv-api-export-test-');
    log = ApiRequestLog(directory: Directory('${directory.path}/records'));
    await log.initialize();
  });

  tearDown(() async {
    log.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'each real request persists separately, preserves raw data and survives restart',
    () async {
      const raw =
          '{\n  "items": [{"name":"贵州茅台","symbol":"600519"}], "total":1\n}';
      final bodies = <String>[];
      final service = HttpMarketService(
        'http://localhost:8787',
        requestLog: log,
        client: MockClient((request) async {
          bodies.add(request.body);
          return http.Response.bytes(
            utf8.encode(raw),
            request.method == 'POST' ? 201 : 200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final query = Uri(
        path: 'v1/instruments',
        queryParameters: {'q': '茅台', 'kind': '股票', 'offset': '50'},
      ).toString();
      await service.request(query);
      await service.request(query);
      final body = {
        'symbol': '600519',
        'instrument_id': 'sh-stock-600519',
        'confidence': 95,
      };
      await service.request('v1/deliveries', body: body);
      expect(log.records.length, 3);
      expect(log.records.map((record) => record.filename).toSet().length, 3);
      for (final record in log.records) {
        final saved = jsonDecode(await record.read()) as Json;
        expect(saved['response']['body_text'], raw);
        expect(
          base64Decode(saved['response']['body_base64']),
          utf8.encode(raw),
        );
        expect(saved['response']['body']['items'][0]['name'], '贵州茅台');
        expect(saved['error'], isNull);
        expect(saved['duration_ms'], isNonNegative);
        expect(
          DateTime.parse(
            saved['completed_at'],
          ).isBefore(DateTime.parse(saved['started_at'])),
          isFalse,
        );
      }
      final post = jsonDecode(await log.records.first.read()) as Json;
      expect(post['request']['method'], 'POST');
      expect(post['request']['body'], body);
      expect(post['request']['body_text'], bodies.last);
      expect(post['response']['status_code'], 201);
      final search = jsonDecode(await log.records.last.read()) as Json;
      expect(search['request']['query_parameters']['q'], ['茅台']);
      expect(search['request']['query_parameters']['offset'], ['50']);
      final restored = ApiRequestLog(
        directory: Directory('${directory.path}/records'),
      );
      await restored.initialize();
      expect(
        restored.records.map((record) => record.filename),
        log.records.map((record) => record.filename),
      );
      restored.dispose();
      service.close();
    },
  );

  test(
    'upstream errors, invalid JSON, connection failures and timeouts are recorded without fake responses',
    () async {
      final replies = [
        http.Response.bytes(utf8.encode('{"error":"上游不可用"}'), 502),
        http.Response('<html>upstream failed</html>', 200),
      ];
      var calls = 0;
      final service = HttpMarketService(
        'http://localhost:8787',
        requestLog: log,
        client: MockClient((_) async {
          calls++;
          if (calls == 3) throw http.ClientException('connection refused');
          if (calls == 4) throw TimeoutException('timeout');
          return replies.removeAt(0);
        }),
      );
      for (var index = 0; index < 4; index++) {
        await expectLater(
          service.request('v1/markets/sh-stock-600519'),
          throwsA(isA<MarketException>()),
        );
      }
      expect(log.records.length, 4);
      final records = await Future.wait(
        log.records.reversed.map(
          (record) async => Json.from(jsonDecode(await record.read())),
        ),
      );
      expect(records[0]['response']['status_code'], 502);
      expect(records[0]['response']['body']['error'], '上游不可用');
      expect(
        records[1]['response']['body_text'],
        '<html>upstream failed</html>',
      );
      expect(records[1]['response']['body'], isNull);
      expect(records[2]['response'], isNull);
      expect(records[3]['response'], isNull);
      expect(records.every((record) => record['error'] != null), isTrue);
      service.close();
    },
  );

  test(
    'ZIP contains one complete JSON per request and export issues no extra API calls',
    () async {
      var calls = 0;
      final service = HttpMarketService(
        'http://localhost:8787',
        requestLog: log,
        client: MockClient((_) async {
          calls++;
          return http.Response('{"status":"ok"}', 200);
        }),
      );
      await service.request('health');
      await service.request('health');
      final zip = await log.exportArchive(
        destination: Directory('${directory.path}/exports'),
      );
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      expect(archive.files.length, 2);
      expect(calls, 2);
      for (final file in archive.files) {
        expect(file.name.endsWith('.json'), isTrue);
        final record = log.records.singleWhere(
          (record) => record.filename == file.name,
        );
        expect(utf8.decode(file.content), await record.read());
      }
      service.close();
    },
  );

  test(
    'storage failure cannot turn a successful market response into a network failure',
    () async {
      final blocked = File('${directory.path}/not-a-directory');
      await blocked.writeAsString('occupied');
      final broken = ApiRequestLog(directory: Directory(blocked.path));
      final service = HttpMarketService(
        'http://localhost:8787',
        requestLog: broken,
        client: MockClient((_) async => http.Response('{"status":"ok"}', 200)),
      );
      expect(await service.request('health'), {'status': 'ok'});
      expect(broken.storageError, contains('保存失败'));
      expect(broken.records, isEmpty);
      service.close();
      broken.dispose();
    },
  );

  test('offline fixture reads produce no HTTP records', () async {
    final service = DemoMarketService();
    await service.assets();
    await service.search('300');
    await service.snapshot('510300');
    expect(log.records, isEmpty);
  });

  test(
    'system sharing receives the saved JSON or ZIP and an iPad popover origin',
    () async {
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return 'dev.fluttercommunity.plus/share/unavailable';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final service = HttpMarketService(
        'http://localhost:8787',
        requestLog: log,
        client: MockClient((_) async => http.Response('{"status":"ok"}', 200)),
      );
      await service.request('health');
      final json = log.records.single.file;
      final zip = await log.exportArchive(destination: directory);
      const actions = ApiFileActions();
      const position = Rect.fromLTWH(20, 40, 100, 48);
      await actions.share(json, position);
      await actions.share(zip, position);
      expect(calls.length, 2);
      expect(calls[0].method, 'share');
      expect(calls[0].arguments['paths'], [json.path]);
      expect(calls[0].arguments['mimeTypes'], ['application/json']);
      expect(calls[1].arguments['paths'], [zip.path]);
      expect(calls[1].arguments['mimeTypes'], ['application/zip']);
      expect(calls[0].arguments['originWidth'], 100.0);
      expect(calls[0].arguments['originHeight'], 48.0);
      service.close();
    },
  );

  testWidgets(
    'settings opens request export and an individual real response can be saved',
    (tester) async {
      await tester.runAsync(() async {
        final service = HttpMarketService(
          'http://localhost:8787',
          requestLog: log,
          client: MockClient(
            (_) async => http.Response('{"status":"ok"}', 200),
          ),
        );
        await service.request('health');
        service.close();
      });
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final controller = MarketController(
        preferences,
        service: DemoMarketService(),
        requestLog: log,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsSheet(controller: controller)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('api-export-entry')));
      await tester.pumpAndSettle();
      expect(find.text('接口数据导出'), findsOneWidget);
      expect(find.text('已保存 1 次真实请求'), findsOneWidget);
      final actions = TestFileActions();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: ApiExportPage(log: log, actions: actions),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('导出此请求'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存 JSON'));
      await tester.pumpAndSettle();
      expect(actions.saved!.path, log.records.single.file.path);
      expect(find.textContaining('已导出到 /chosen/'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      log = ApiRequestLog(directory: directory);
    },
  );
}
