import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rwkv_prediction/device_model.dart';
import 'package:rwkv_prediction/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const path = String.fromEnvironment('DEVICE_MODEL_PATH');
  test(
    'real GGUF runs inside the client process without a model server',
    () async {
      expect(await verifyDeviceModel(path), isTrue);
      const quotePath = String.fromEnvironment('DEVICE_QUOTE_PATH');
      final fixture = jsonDecode(
        await rootBundle.loadString('assets/market-demo.json'),
      );
      final quote = quotePath.isEmpty
          ? Json.from(fixture['snapshots']['510300'])
          : Json.from(jsonDecode(await File(quotePath).readAsString()));
      quote.remove('predictions');
      final response = await LlamaDeviceRuntime().generate(path, quote);
      final snapshot = MarketSnapshot(response);
      expect(snapshot.isOnDevice, isTrue);
      expect(snapshot.predictions[20]!.usage['input_tokens'], greaterThan(0));
      expect(snapshot.predictions[20]!.usage['output_tokens'], greaterThan(0));
      debugPrint(
        jsonEncode({
          'source': snapshot.source,
          'as_of': snapshot.asOf,
          'forecast_source': snapshot.forecastSource,
          'usage': snapshot.predictions[5]!.usage,
          'targets': {
            for (final entry in (response['predictions'] as Json).entries)
              entry.key: {
                'return_pct': entry.value['target_return_pct'],
                'explanation': entry.value['explanation'],
              },
          },
        }),
      );
      const outputPath = String.fromEnvironment('DEVICE_RESULT_PATH');
      if (outputPath.isNotEmpty) {
        await File(outputPath).writeAsString(jsonEncode(response));
      }
    },
    skip: path.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
