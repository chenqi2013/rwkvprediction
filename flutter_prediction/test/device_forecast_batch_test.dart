import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rwkv_prediction/device_model.dart';
import 'package:rwkv_prediction/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const modelPath = String.fromEnvironment('DEVICE_MODEL_PATH');
  const batchPath = String.fromEnvironment('DEVICE_BATCH_PATH');
  const outputPath = String.fromEnvironment('DEVICE_BATCH_RESULT_PATH');
  test(
    'evaluate frozen historical inputs using the actual device runtime',
    () async {
      expect(await verifyDeviceModel(modelPath), isTrue);
      final batch = jsonDecode(await File(batchPath).readAsString()) as List;
      final output = File(outputPath);
      expect(await output.exists(), isFalse);
      for (final item in batch) {
        final record = <String, dynamic>{
          'id': item['id'],
          'input_sha256': item['input_sha256'],
        };
        try {
          final response = await LlamaDeviceRuntime().generate(
            modelPath,
            Json.from(item['quote']),
          );
          record['predicted_return_pct'] = {
            for (final horizon in ['5', '20', '60'])
              horizon: response['predictions'][horizon]['target_return_pct'],
          };
          record['latency_ms'] =
              response['predictions']['5']['usage']['latency_ms'];
          record['usage'] = response['predictions']['5']['usage'];
          record['explanations'] = {
            for (final horizon in ['5', '20', '60'])
              horizon: response['predictions'][horizon]['explanation'],
          };
        } catch (error) {
          record['error'] = error.toString();
        }
        await output.writeAsString(
          '${jsonEncode(record)}\n',
          mode: FileMode.append,
        );
      }
    },
    skip: modelPath.isEmpty || batchPath.isEmpty || outputPath.isEmpty,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
