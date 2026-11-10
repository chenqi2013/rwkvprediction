import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rwkv_prediction/minute_models.dart';
import 'package:rwkv_prediction/rwkv_forecast.dart';
import 'package:rwkv_prediction/rwkv_forecast_panel.dart';
import 'package:rwkv_prediction/rwkv_model.dart';
import 'package:rwkv_prediction/rwkv_native.dart';
import 'package:rwkv_prediction/theme.dart';

Map<String, dynamic> fixture(String session) =>
    jsonDecode(File('test/fixtures/rwkv_$session.json').readAsStringSync());

class TestModel extends RwkvModel {
  Completer<RwkvForecast>? pending;
  @override
  Future<void> initialize() async {
    ready = true;
    status = '测试用预测运行库';
  }

  @override
  Future<RwkvForecast> predict(MinuteSnapshot snapshot, String origin) async {
    if (pending != null) return pending!.future;
    return result(snapshot, origin);
  }

  RwkvForecast result(MinuteSnapshot snapshot, String origin) => RwkvForecast(
    instrumentId: snapshot.instrument.id,
    origin: origin,
    anchor: snapshot.bars.firstWhere((b) => b.timestamp == origin).close,
    raw: List<double>.from(fixture('morning')['raw_reference']),
    latencyMs: 1,
    inputHash: sha256
        .convert(prepareRwkvFeatures(snapshot, origin).buffer.asUint8List())
        .toString(),
    universeId: snapshot.market!['universe_id'],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final session in ['morning', 'afternoon']) {
    test(
      '$session features match original Python processor at FP32 boundary',
      () {
        final data = fixture(session);
        final snapshot = MinuteSnapshot(data['snapshot']);
        final actual = prepareRwkvFeatures(snapshot, data['origin']);
        final expected = List<num>.from(data['features']);
        expect(actual.length, 64 * 23);
        for (var i = 0; i < actual.length; ++i) {
          expect(
            actual[i],
            closeTo(expected[i].toDouble(), 2e-6),
            reason: 'feature $i',
          );
        }
        expect(rwkvOrigins(snapshot), contains(data['origin']));
        final times = rwkvOrigins(snapshot).map(minuteTime);
        expect(
          times.every(
            (t) => t.hour * 60 + t.minute <= (session == 'morning' ? 660 : 870),
          ),
          isTrue,
        );
      },
    );
  }
  test(
    'future bars and future market statistics never affect model features',
    () {
      final data = fixture('morning');
      final before = prepareRwkvFeatures(
        MinuteSnapshot(data['snapshot']),
        data['origin'],
      );
      for (final bar in data['snapshot']['bars']) {
        if ((bar['timestamp'] as String).compareTo(data['origin']) > 0) {
          for (final key in ['open', 'high', 'low', 'close']) {
            bar[key] *= 10;
          }
          bar['volume'] *= 100;
        }
      }
      for (final stat in data['snapshot']['market_statistics']['points']) {
        if ((stat['timestamp'] as String).compareTo(data['origin']) > 0) {
          stat['market_return'] = 99;
        }
      }
      expect(
        prepareRwkvFeatures(MinuteSnapshot(data['snapshot']), data['origin']),
        before,
      );
    },
  );
  test(
    'missing minute, open, market stats, wrong source and ETF are rejected',
    () {
      for (final change in <void Function(Map<String, dynamic>)>[
        (s) => s['bars'].removeAt(10),
        (s) => s['bars'][20]['open'] = null,
        (s) => s['market_statistics']['points'][70]['count'] = 0,
        (s) => s['market_statistics']['points'][70]['market_volatility'] = -1,
        (s) => s['instrument']['kind'] = 'ETF',
        (s) => s['source'] = 'demo',
      ]) {
        final data = fixture('morning');
        change(data['snapshot']);
        expect(
          () => prepareRwkvFeatures(
            MinuteSnapshot(data['snapshot']),
            data['origin'],
          ),
          throwsFormatException,
        );
      }
      final data = fixture('morning');
      expect(
        () => rwkvPrefix(MinuteSnapshot(data['snapshot']), '2026-11-06T11:01'),
        throwsFormatException,
      );
    },
  );
  test(
    'quantiles sorted, decode anchored cumulative log returns and reject overflow',
    () {
      RwkvForecast value(List<double> raw) => RwkvForecast(
        instrumentId: 'test',
        origin: '2026-11-06T10:35',
        anchor: 10,
        raw: raw,
        latencyMs: 1,
        inputHash: 'test',
        universeId: 'test',
      );
      final prices = value([
        for (var i = 0; i < 30; ++i) ...[
          9.0,
          8.0,
          7.0,
          6.0,
          5.0,
          4.0,
          3.0,
          2.0,
          1.0,
        ],
      ]).prices;
      expect(prices.first[4], closeTo(10 * math.exp(.05), 1e-10));
      expect(prices.first, prices.last);
      expect(
        () => value(List.filled(270, double.infinity)).prices,
        throwsFormatException,
      );
      expect(
        () => value(List.filled(270, 100000)).prices,
        throwsFormatException,
      );
    },
  );
  for (final width in [390.0, 1100.0]) {
    testWidgets('forecast charts and historical comparison render at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final data = fixture('morning');
      final snapshot = MinuteSnapshot(data['snapshot']);
      final model = TestModel();
      await tester.pumpWidget(
        MaterialApp(
          theme: marketTheme(true),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RwkvForecastPanel(snapshot: snapshot, model: model),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('run-rwkv-forecast'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(RwkvForecastChart), findsOneWidget);
      expect(
        find.byKey(const ValueKey('rwkv-forecast-summary')),
        findsOneWidget,
      );
      expect(find.textContaining('维持现价 MAE'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }
  testWidgets(
    'changing origin discards pending output; refresh preserves forecast for identical input',
    (tester) async {
      final data = fixture('morning');
      final snapshot = MinuteSnapshot(data['snapshot']);
      final model = TestModel();
      Widget page(MinuteSnapshot s) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RwkvForecastPanel(snapshot: s, model: model),
          ),
        ),
      );
      await tester.pumpWidget(page(snapshot));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('run-rwkv-forecast'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(RwkvForecastChart), findsOneWidget);
      final newer = MinuteSnapshot(jsonDecode(jsonEncode(data['snapshot'])));
      await tester.pumpWidget(page(newer));
      await tester.pumpAndSettle();
      expect(find.byType(RwkvForecastChart), findsOneWidget);
      model.pending = Completer<RwkvForecast>();
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      final dropdown = find.byKey(const ValueKey('rwkv-origin'));
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('10:59').last);
      await tester.pumpAndSettle();
      model.pending!.complete(
        model.result(snapshot, rwkvOrigins(snapshot).last),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RwkvForecastChart), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );
  test(
    'real native runtime matches PyTorch reference with verified BF16 weights',
    () async {
      final directory = Platform.environment['RWKV_TEST_MODEL_DIR']!;
      final manifest = jsonDecode(
        File('assets/rwkv/manifest.json').readAsStringSync(),
      );
      final pins = Map<String, String>.from(manifest['sha256'])
        ..removeWhere((name, _) => !name.endsWith('.safetensors'));
      await packRwkvModel(directory, pins);
      for (final session in ['morning', 'afternoon']) {
        final data = fixture(session);
        final features = prepareRwkvFeatures(
          MinuteSnapshot(data['snapshot']),
          data['origin'],
        );
        final raw = nativeMinuteForecast('$directory/rwkv21m.bin', features);
        final expected = List<num>.from(data['raw_reference']);
        for (var i = 0; i < 270; ++i) {
          expect(
            raw[i],
            closeTo(expected[i].toDouble(), .004),
            reason: '$session output $i',
          );
        }
        expect(
          nativeMinuteForecast('$directory/rwkv21m.bin', features),
          raw,
          reason: 'state must reset for every inference',
        );
      }
      expect(
        () => nativeMinuteForecast(
          '$directory/missing.bin',
          Float32List(64 * 23),
        ),
        throwsFormatException,
      );
    },
    skip: Platform.environment['RWKV_TEST_MODEL_DIR'] == null
        ? 'Set RWKV_TEST_MODEL_DIR to run the 40 MiB real-weight native test'
        : false,
  );
}
