import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rwkv_prediction/main.dart';
import 'package:rwkv_prediction/market_controller.dart';
import 'package:rwkv_prediction/market_service.dart';
import 'package:rwkv_prediction/minute_market_page.dart';
import 'package:rwkv_prediction/minute_models.dart';
import 'package:rwkv_prediction/models.dart';
import 'package:rwkv_prediction/theme.dart';

Json fixture({String symbol = '600519', String date = '2026-11-09'}) => {
  'instrument': {
    'id': 'sh-stock-$symbol',
    'symbol': symbol,
    'name': '测试股票',
    'kind': '股票',
    'market': 'sh',
    'subtitle': '上交所',
  },
  'granularity': '1m',
  'timezone': 'Asia/Shanghai',
  'price_adjustment': 'none',
  'volume_unit': 'share',
  'date': date,
  'available_dates': ['2026-11-09', '2026-11-06'],
  'as_of': '${date}T10:35:00+08:00',
  'market_vendor': 'sina',
  'stale': false,
  'bars': [
    for (var i = 0; i < 65; i++)
      {
        'timestamp': DateTime.parse(
          '${date}T09:31',
        ).add(Duration(minutes: i)).toIso8601String().substring(0, 16),
        'session': '$date-am',
        'open': 10.0,
        'high': 10.2,
        'low': 9.8,
        'close': 10 + i / 1000,
        'volume': 1000.0 + i,
        'amount': 10000.0,
      },
  ],
  'rwkv_input': {
    'context_bars': 65,
    'status': 'unavailable',
    'reasons': ['尚未加载同期市场统计'],
  },
  'market_statistics': null,
  'warnings': [],
};

class MinuteService extends DemoMarketService {
  final requests = <String>[];
  bool dailyUnavailable = false;
  bool fail = false;
  Completer<MinuteSnapshot>? pending;
  @override
  Future<MarketSnapshot> snapshot(String symbol) async {
    if (dailyUnavailable) throw const MarketException('请先安装日线预测模型');
    return super.snapshot(symbol);
  }

  @override
  Future<MinuteSnapshot> minutes(
    String identity, {
    String? date,
    bool includeMarket = false,
  }) async {
    requests.add('$identity:$date:$includeMarket');
    if (pending != null) return pending!.future;
    if (fail) throw const MarketException('分钟上游暂不可用');
    final data = fixture(date: date ?? '2026-11-09');
    if (includeMarket) {
      data['market_statistics'] = {'size': 8, 'loaded_count': 7};
      data['warnings'] = ['市场统计使用固定实验集合'];
    }
    return MinuteSnapshot(data);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  test(
    'minute HTTP request skips model readiness and preserves query',
    () async {
      final service = HttpMarketService(
        'http://localhost:8787',
        client: MockClient((request) async {
          expect(request.url.path, '/v1/minute-markets/sh-stock-600519');
          expect(request.url.queryParameters, {
            'date': '2026-11-09',
            'include_market': '1',
          });
          return http.Response.bytes(utf8.encode(jsonEncode(fixture())), 200);
        }),
      );
      final value = await service.minutes(
        'sh-stock-600519',
        date: '2026-11-09',
        includeMarket: true,
      );
      expect(value.bars.length, 65);
      expect(value.shares, isTrue);
      service.close();
    },
  );

  test(
    'invalid OHLC, unordered timestamps and cutoff mismatch are rejected',
    () {
      for (final mutate in <void Function(Json)>[
        (data) => data['bars'][0]['close'] = 500,
        (data) => data['bars'][1]['timestamp'] = data['bars'][0]['timestamp'],
        (data) => data['as_of'] = '2026-11-09T10:36:00+08:00',
      ]) {
        final data = fixture();
        mutate(data);
        expect(() => MinuteSnapshot(data), throwsFormatException);
      }
    },
  );

  testWidgets('minute entry works when daily/model loading fails', (
    tester,
  ) async {
    final service = MinuteService()..dailyUnavailable = true;
    final controller = MarketController(preferences, service: service);
    // The requested initial ETF identity intentionally cannot resolve the
    // independent minute fixture; verify that no model installation is needed.
    await tester.pumpWidget(PredictionApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('minute-market-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(MinuteMarketPage), findsOneWidget);
    expect(service.requests, isNotEmpty);
    expect(find.textContaining('分钟行情与请求的标的'), findsOneWidget);
    expect(controller.deviceModel.ready, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final size in [const Size(390, 844), const Size(1200, 850)]) {
    testWidgets('minute chart, date selection, stats and refresh at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = MinuteService();
      final controller = MarketController(preferences, service: service);
      await tester.pumpWidget(
        MaterialApp(
          theme: marketTheme(true),
          home: MinuteMarketPage(
            controller: controller,
            instrument: MarketInstrument(fixture()['instrument']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MinutePriceChart), findsOneWidget);
      final chart = find.byType(CustomPaint).last;
      await tester.tap(chart);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('minute-chart-inspection')),
        findsOneWidget,
      );
      final dropdown = find.byKey(const ValueKey('minute-date'));
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026-11-06').last);
      await tester.pumpAndSettle();
      expect(service.requests.last, contains(':2026-11-06:false'));
      final prepare = find.byKey(const ValueKey('prepare-minute-market'));
      await tester.ensureVisible(prepare);
      await tester.tap(prepare);
      await tester.pumpAndSettle();
      expect(service.requests.last, endsWith(':true'));
      expect(find.text('固定实验集合 8 只，已加载 7 只。'), findsOneWidget);
      service.fail = true;
      await tester.tap(find.byTooltip('刷新分钟行情'));
      await tester.pumpAndSettle();
      expect(find.textContaining('刷新失败，保留原行情'), findsOneWidget);
      expect(find.byType(MinutePriceChart), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  testWidgets('leaving page while minute request is pending is safe', (
    tester,
  ) async {
    final service = MinuteService()..pending = Completer<MinuteSnapshot>();
    final controller = MarketController(preferences, service: service);
    await tester.pumpWidget(
      MaterialApp(
        home: MinuteMarketPage(
          controller: controller,
          instrument: MarketInstrument(fixture()['instrument']),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    service.pending!.complete(MinuteSnapshot(fixture()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    controller.dispose();
  });
}
