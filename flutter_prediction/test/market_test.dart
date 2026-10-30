import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rwkv_prediction/main.dart';
import 'package:rwkv_prediction/market_controller.dart';
import 'package:rwkv_prediction/market_service.dart';
import 'package:rwkv_prediction/models.dart';
import 'package:rwkv_prediction/forecast_chart.dart';
import 'package:rwkv_prediction/sheets.dart';
import 'package:rwkv_prediction/api_request_log.dart';

class NoDiskRequestLog extends ApiRequestLog {
  @override
  Future<void> record(Json document) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Json fixture;
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    fixture = Json.from(
      jsonDecode(await rootBundle.loadString('assets/market-demo.json')),
    );
  });

  test(
    'HTTP contract decodes real source, sends selected forecast and confidence',
    () async {
      Json? delivered;
      final snapshotJson = Json.from(fixture['snapshots']['510300'])
        ..['source'] = 'akshare'
        ..['market_vendor'] = 'sina';
      final service = HttpMarketService(
        'http://localhost:8787/',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            delivered = Json.from(jsonDecode(request.body));
            expect(request.url.path, '/v1/deliveries');
            return http.Response(jsonEncode({'id': 'test-receipt'}), 201);
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(
                request.url.path == '/v1/assets'
                    ? fixture['assets']
                    : snapshotJson,
              ),
            ),
            200,
          );
        }),
      );
      expect((await service.assets()).length, 5);
      final snapshot = await service.snapshot('510300');
      expect(snapshot.isLive, isTrue);
      expect(snapshot.vendor, 'sina');
      final forecast = snapshot.predictions[60]!;
      await service.deliver(snapshot, forecast, 95, 'in_app');
      expect(delivered, {
        'symbol': '510300',
        'instrument_id': 'sh-etf-510300',
        'prediction_id': forecast.id,
        'confidence': 95,
        'channel': 'in_app',
      });
      service.close();
    },
  );

  test(
    'HTTP upstream failure stays an error instead of becoming mock data',
    () async {
      final service = HttpMarketService(
        'http://localhost:8787',
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(jsonEncode({'error': 'AKShare 上游不可用'})),
            502,
          ),
        ),
      );
      await expectLater(
        service.assets(),
        throwsA(
          isA<MarketException>().having(
            (error) => error.message,
            'message',
            'AKShare 上游不可用',
          ),
        ),
      );
      service.close();
    },
  );

  test(
    'theme, favorites and issued forecast persist independently of later selection',
    () async {
      final service = DemoMarketService();
      await service.assets();
      final controller = MarketController(preferences, service: service);
      expect(controller.dark, isTrue);
      await controller.load();
      await controller.setDark(false);
      await controller.toggleFavorite('510300');
      controller.setHorizon(60);
      controller.setConfidence(95);
      final receipt = await controller.deliver('in_app');
      await controller.load(selectedSymbol: '000300');
      final restored = MarketController(
        preferences,
        service: DemoMarketService(),
      );
      expect(restored.dark, isFalse);
      expect(restored.favorites, contains('sh-etf-510300'));
      expect(restored.deliveries.single['id'], receipt['id']);
      expect(restored.deliveries.single['forecast']['horizon'], 60);
      expect(restored.deliveries.single['forecast']['confidence'], 95);
      expect(restored.deliveries.single['symbol'], '510300');
      controller.dispose();
      restored.dispose();
    },
  );

  test('invalid address cannot replace active API configuration', () async {
    final controller = MarketController(
      preferences,
      service: DemoMarketService(),
    );
    final original = controller.baseUrl;
    await expectLater(
      controller.configure('file:///tmp/fake', false),
      throwsA(isA<MarketException>()),
    );
    expect(controller.baseUrl, original);
    controller.dispose();
  });

  test('invalid quantile ordering is rejected', () {
    final data = Json.from(fixture['snapshots']['510300']);
    data['predictions']['20']['points'][0]['p10'] = 100000;
    expect(() => MarketSnapshot(data), throwsFormatException);
  });

  test(
    'search encodes names, kinds and pagination; selected stocks persist in favorites',
    () async {
      final stock = {
        'id': 'sz-stock-000001',
        'symbol': '000001',
        'name': '平安银行',
        'kind': '股票',
        'market': 'sz',
        'subtitle': '深交所',
      };
      final stockSnapshot = Json.from(
        jsonDecode(jsonEncode(fixture['snapshots']['000001'])),
      )..['source'] = 'akshare';
      stockSnapshot['asset'].addAll(stock);
      final paths = <String>[];
      final service = HttpMarketService(
        'http://localhost:8787',
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/v1/instruments') {
            expect(request.url.queryParameters, {
              'q': '平安 银行',
              'kind': '股票',
              'offset': '50',
              'limit': '50',
            });
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'items': [stock],
                  'total': 51,
                  'has_more': false,
                  'warnings': [],
                }),
              ),
              200,
            );
          }
          expect(request.url.path, '/v1/markets/sz-stock-000001');
          return http.Response.bytes(
            utf8.encode(jsonEncode(stockSnapshot)),
            200,
          );
        }),
      );
      final result = await service.search('平安 银行', kind: '股票', offset: 50);
      expect(result.items.single.id, 'sz-stock-000001');
      final controller = MarketController(
        preferences,
        service: service,
        requestLog: NoDiskRequestLog(),
      );
      await controller.load(selectedSymbol: result.items.single.id);
      expect(controller.error, isNull);
      expect(controller.snapshot!.asset.kind, '股票');
      expect(controller.snapshot!.history.length, 61);
      await controller.toggleFavorite(controller.snapshot!.asset.id);
      await controller.toggleFavorite('sh-index-000001');
      final restored = MarketController(
        preferences,
        service: DemoMarketService(),
      );
      expect(
        restored.favorites,
        containsAll(['sz-stock-000001', 'sh-index-000001']),
      );
      expect(
        restored.assets
            .singleWhere((asset) => asset.id == 'sz-stock-000001')
            .name,
        '平安银行',
      );
      expect(paths, isNot(contains('/v1/assets')));
      controller.dispose();
      restored.dispose();
    },
  );

  testWidgets(
    'remote search ignores late replies and distinguishes stock and index codes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <String, Completer<http.Response>>{};
      final stock = {
        'id': 'sz-stock-000001',
        'symbol': '000001',
        'name': '平安银行',
        'kind': '股票',
        'market': 'sz',
        'subtitle': '深交所',
      };
      final index = {
        'id': 'sh-index-000001',
        'symbol': '000001',
        'name': '上证指数',
        'kind': '指数',
        'market': 'sh',
        'subtitle': '上交所',
      };
      final service = HttpMarketService(
        'http://localhost:8787',
        client: MockClient((request) {
          final response = Completer<http.Response>();
          requests[request.url.queryParameters['q']!] = response;
          return response.future;
        }),
      );
      final controller = MarketController(
        preferences,
        service: service,
        requestLog: NoDiskRequestLog(),
      );
      http.Response response(List<Json> items) => http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'items': items,
            'total': items.length,
            'has_more': false,
            'warnings': [],
          }),
        ),
        200,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 700,
              child: AssetPicker(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), '000001');
      await tester.pump(const Duration(milliseconds: 400));
      requests['000001']!.complete(response([stock, index]));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('asset-sz-stock-000001')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('asset-sh-index-000001')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('asset-sz-stock-000001')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.favorites, contains('sz-stock-000001'));
      expect(
        controller.assets.any((asset) => asset.id == 'sz-stock-000001'),
        isTrue,
      );
      expect(preferences.getString('instruments'), contains('sz-stock-000001'));
      requests['']!.complete(response([]));
      await tester.pumpAndSettle();
      expect(find.text('平安银行'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '无结果');
      await tester.pump(const Duration(milliseconds: 400));
      requests['无结果']!.complete(
        http.Response.bytes(
          utf8.encode(jsonEncode({'error': '股票名单获取失败'})),
          502,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('股票名单获取失败'), findsOneWidget);
      expect(find.text('没有找到相关标的'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'picker loads pages on scroll, avoids duplicate requests and retries in place',
    (tester) async {
      final offsets = <int>[];
      final responses = <Completer<http.Response>>[];
      final service = HttpMarketService(
        'http://localhost:8787',
        client: MockClient((request) {
          offsets.add(int.parse(request.url.queryParameters['offset']!));
          final response = Completer<http.Response>();
          responses.add(response);
          return response.future;
        }),
      );
      final controller = MarketController(
        preferences,
        service: service,
        requestLog: NoDiskRequestLog(),
      );
      http.Response page(int offset, {required bool hasMore}) =>
          http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'items': List.generate(20, (index) {
                  final symbol = (600000 + offset + index).toString();
                  return {
                    'id': 'sh-stock-$symbol',
                    'symbol': symbol,
                    'name': '测试股票$symbol',
                    'kind': '股票',
                    'market': 'sh',
                    'subtitle': '上交所',
                  };
                }),
                'total': 60,
                'has_more': hasMore,
                'warnings': [],
              }),
            ),
            200,
          );
      Future<void> scrollToBottom() async {
        final list = tester.widget<ListView>(find.byType(ListView));
        list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AssetPicker(controller: controller)),
        ),
      );
      responses[0].complete(page(0, hasMore: true));
      await tester.pumpAndSettle();
      expect(offsets, [0]);

      await scrollToBottom();
      expect(offsets, [0, 20]);
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(offsets, [0, 20]);

      responses[1].complete(
        http.Response.bytes(utf8.encode(jsonEncode({'error': '分页加载失败'})), 502),
      );
      await tester.pumpAndSettle();
      expect(find.text('分页加载失败'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('asset-sh-stock-600019')),
        findsOneWidget,
      );
      await scrollToBottom();
      expect(offsets, [0, 20]);
      await tester.tap(find.text('重试加载'));
      await tester.pump();
      expect(offsets, [0, 20, 20]);

      responses[2].complete(page(20, hasMore: true));
      await tester.pumpAndSettle();
      expect(find.text('分页加载失败'), findsNothing);
      final list = tester.widget<ListView>(find.byType(ListView));
      list.controller!.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('asset-sh-stock-600000')),
        findsOneWidget,
      );
      await scrollToBottom();
      expect(offsets, [0, 20, 20, 40]);

      responses[3].complete(page(40, hasMore: false));
      await tester.pumpAndSettle();
      await scrollToBottom();
      expect(
        find.byKey(const ValueKey('asset-sh-stock-600059')),
        findsOneWidget,
      );
      expect(offsets, [0, 20, 20, 40]);
      expect(find.textContaining('加载更多'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  for (final size in [const Size(390, 844), const Size(1440, 1000)]) {
    testWidgets('forecast, theme, chart and delivery work at ${size.width}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = DemoMarketService();
      await tester.runAsync(service.assets);
      final controller = MarketController(preferences, service: service);
      await tester.pumpWidget(PredictionApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('走势预测'), findsOneWidget);
      expect(find.text('模拟行情 · 离线演示'), findsWidgets);
      if (size.width >= 1100) {
        expect(find.text('最近浏览'), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('quick-sz-etf-159915')));
      await tester.pumpAndSettle();
      expect(controller.snapshot?.asset.symbol, '159915');
      await tester.tap(find.byIcon(Icons.candlestick_chart_outlined));
      await tester.pumpAndSettle();
      expect(find.text('历史行情'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.graphic_eq).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('horizon-5')));
      await tester.pumpAndSettle();
      expect(controller.horizon, 5);
      await tester.tap(find.text('80% 区间').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('95% 预测区间'));
      await tester.pumpAndSettle();
      expect(controller.confidence, 95);
      final chart = find.byType(ForecastChart).first;
      await tester.ensureVisible(chart);
      await tester.drag(chart, const Offset(70, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(controller.dark, isFalse);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下发预测'));
      await tester.pumpAndSettle();
      final confirm = find.text('确认下发');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.text('预测已下发'), findsOneWidget);
      expect(controller.deliveries.single['forecast']['confidence'], 95);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索 ETF、指数和股票'));
      await tester.pumpAndSettle();
      final indexRow = find.byKey(const ValueKey('asset-sh-index-000300'));
      await tester.tap(
        find.descendant(of: indexRow, matching: find.byType(IconButton)),
      );
      await tester.pumpAndSettle();
      expect(controller.favorites, contains('sh-index-000300'));
      await tester.tap(find.byKey(const ValueKey('asset-sh-index-000300')));
      await tester.pumpAndSettle();
      expect(controller.snapshot?.asset.symbol, '000300');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }
}
