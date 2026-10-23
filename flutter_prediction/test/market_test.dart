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
      expect(restored.favorites, contains('510300'));
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
      await tester.tap(find.byTooltip('搜索 ETF 和指数'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('asset-000300')));
      await tester.pumpAndSettle();
      expect(controller.snapshot?.asset.symbol, '000300');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }
}
