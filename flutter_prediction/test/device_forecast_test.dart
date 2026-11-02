import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rwkv_prediction/device_forecast.dart';
import 'package:rwkv_prediction/device_model.dart';
import 'package:rwkv_prediction/device_model_page.dart';
import 'package:rwkv_prediction/market_service.dart';
import 'package:rwkv_prediction/models.dart';

class TestDeviceModel extends DeviceModel {
  Json? input;
  Object? failure;

  @override
  Future<void> initialize() async {
    ready = true;
    notifyListeners();
  }

  @override
  Future<Json> predict(Json quote) async {
    input = quote;
    if (failure != null) throw failure!;
    return projectDeviceForecast(quote, estimates(), {
      'input_tokens': 100,
      'output_tokens': 60,
      'latency_ms': 12,
    });
  }
}

class PendingRuntime implements ForecastRuntime {
  final task = Completer<Json>();
  bool cancelled = false;
  @override
  Future<Json> generate(String path, Json quote) => task.future;
  @override
  void cancel() {
    cancelled = true;
    if (!task.isCompleted) task.completeError(const FormatException('已取消'));
  }
}

Json estimates() => {
  for (final horizon in [5, 20, 60])
    '$horizon': {
      'return_pct': horizon == 5 ? -2 : horizon / 10,
      'summary': '根据样例历史价格估算，未来走势存在不确定性。',
    },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Json quote;
  setUp(() async {
    final fixture = jsonDecode(
      await rootBundle.loadString('assets/market-demo.json'),
    );
    quote = Json.from(fixture['snapshots']['510300'])..remove('predictions');
  });

  test('device projection anchors targets and orders all future quantiles', () {
    final result = projectDeviceForecast(quote, estimates(), {
      'latency_ms': 12,
    });
    final snapshot = MarketSnapshot(result);
    expect(snapshot.isOnDevice, isTrue);
    expect(snapshot.predictions.keys, [5, 20, 60]);
    for (final horizon in [5, 20, 60]) {
      final forecast = snapshot.predictions[horizon]!;
      final raw = result['predictions']['$horizon'];
      expect(forecast.isOnDevice, isTrue);
      expect(raw['backtest']['status'], 'not_evaluated');
      expect(
        forecast.last.median,
        closeTo(
          snapshot.asset.price *
              (1 + estimates()['$horizon']['return_pct'] / 100),
          1e-9,
        ),
      );
      String previous = quote['history'].last['date'];
      for (final point in raw['points']) {
        final values = [
          'p025',
          'p10',
          'p25',
          'p50',
          'p75',
          'p90',
          'p975',
        ].map((key) => number(point[key])).toList();
        expect(values.every((value) => value.isFinite && value > 0), isTrue);
        expect(values, orderedEquals([...values]..sort()));
        expect((point['date'] as String).compareTo(previous), greaterThan(0));
        expect(DateTime.parse(point['date']).weekday, lessThanOrEqualTo(5));
        previous = point['date'];
      }
    }
  });

  test('invalid model output and inconsistent market history are rejected', () {
    for (final invalid in [
      '{}',
      jsonEncode(estimates()..remove('60')),
      jsonEncode(estimates()..['5']['return_pct'] = 101),
      jsonEncode(estimates()..['20']['summary'] = '短'),
    ]) {
      expect(() => parseDeviceEstimates(invalid), throwsFormatException);
    }
    quote['asset']['price'] = 0;
    expect(() => quoteFeatures(quote), throwsFormatException);
  });

  test(
    'HTTP requests prices only, predicts on device and saves locally',
    () async {
      final runtime = TestDeviceModel();
      final requests = <http.Request>[];
      final service = HttpMarketService(
        'http://localhost:8787',
        deviceModel: runtime,
        client: MockClient((request) async {
          requests.add(request);
          expect(request.url.queryParameters, {'inference': 'device'});
          return http.Response.bytes(utf8.encode(jsonEncode(quote)), 200);
        }),
      );
      final snapshot = await service.snapshot('510300');
      expect(runtime.input!.containsKey('predictions'), isFalse);
      final receipt = await service.deliver(
        snapshot,
        snapshot.predictions[20]!,
        95,
        'in_app',
      );
      expect(requests.length, 1);
      expect(receipt['status'], 'saved_locally');
      expect(receipt['forecast']['forecast_source'], 'on_device');
      runtime.failure = const FormatException('模型失败');
      await expectLater(service.snapshot('510300'), throwsFormatException);
      service.close();
      runtime.dispose();
    },
  );

  test('cancelled pending quote never starts device inference', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    final runtime = TestDeviceModel();
    final service = HttpMarketService(
      'http://localhost:8787',
      deviceModel: runtime,
      client: MockClient((request) {
        started.complete();
        return response.future;
      }),
    );
    final pending = service.snapshot('510300');
    final assertion = expectLater(pending, throwsA(isA<MarketException>()));
    await started.future;
    service.cancelPending();
    response.complete(http.Response.bytes(utf8.encode(jsonEncode(quote)), 200));
    await assertion;
    expect(runtime.input, isNull);
    service.close();
    runtime.dispose();
  });

  test(
    'runtime cancellation releases busy state and invalid imports stay unready',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'device-model-test',
      );
      final runtime = PendingRuntime();
      final model = DeviceModel(directory: directory, runtime: runtime);
      try {
        await model.initialize();
        await model.importStream(Stream.value([1, 2, 3]));
        expect(model.ready, isFalse);
        expect(model.error, contains('SHA-256'));
        expect(await File('${model.modelPath}.part').exists(), isFalse);
        model.ready = true;
        final prediction = model.predict(quote);
        final assertion = expectLater(prediction, throwsFormatException);
        await Future<void>.delayed(Duration.zero);
        expect(model.busy, isTrue);
        await model.cancelAndWait();
        await assertion;
        expect(runtime.cancelled, isTrue);
        expect(model.busy, isFalse);
      } finally {
        model.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  for (final width in [390.0, 1440.0]) {
    testWidgets('device page performs an offline sample run at $width px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = TestDeviceModel();
      await tester.pumpWidget(MaterialApp(home: DeviceModelPage(model: model)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('device-model-test')),
      );
      await tester.tap(find.byKey(const ValueKey('device-model-test')));
      await tester.pump();
      for (var attempt = 0; model.input == null && attempt < 50; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(model.input!['source'], 'mock');
      expect(model.input!.containsKey('predictions'), isFalse);
      expect(find.textContaining('5 个交易日 ·'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('60 个交易日 ·'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.textContaining('60 个交易日 ·'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }
}
