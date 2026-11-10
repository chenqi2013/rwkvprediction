import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

@Native<
  Int32 Function(
    Pointer<Utf8>,
    Pointer<Float>,
    Pointer<Float>,
    Pointer<Utf8>,
    Int32,
  )
>(
  symbol: 'rwkv_minute_predict',
  assetId: 'package:rwkv_prediction/rwkv_native.dart',
)
external int _predict(
  Pointer<Utf8> path,
  Pointer<Float> input,
  Pointer<Float> output,
  Pointer<Utf8> error,
  int capacity,
);

Float32List nativeMinuteForecast(String modelPath, Float32List features) {
  if (features.length != 64 * 23 || features.any((v) => !v.isFinite)) {
    throw const FormatException('RWKV 输入必须为有限的 64×23 特征');
  }
  final path = modelPath.toNativeUtf8();
  final input = calloc<Float>(features.length);
  final output = calloc<Float>(270);
  final error = calloc<Uint8>(1024).cast<Utf8>();
  try {
    input.asTypedList(features.length).setAll(0, features);
    if (_predict(path, input, output, error, 1024) != 0) {
      throw FormatException('RWKV 本地推理失败：${error.toDartString()}');
    }
    final result = Float32List.fromList(output.asTypedList(270));
    if (result.any((v) => !v.isFinite)) {
      throw const FormatException('RWKV 返回非有限数值');
    }
    return result;
  } finally {
    calloc.free(path);
    calloc.free(input);
    calloc.free(output);
    calloc.free(error);
  }
}
