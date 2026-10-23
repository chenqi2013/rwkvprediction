import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

class MarketException implements Exception {
  const MarketException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class MarketService {
  Future<List<MarketAsset>> assets();
  Future<MarketSnapshot> snapshot(String symbol);
  Future<Json> deliver(
    MarketSnapshot snapshot,
    Forecast forecast,
    int confidence,
    String channel,
  );
  void close() {}
}

class HttpMarketService extends MarketService {
  HttpMarketService(this.baseUrl, {http.Client? client})
    : client = client ?? http.Client();
  final String baseUrl;
  final http.Client client;

  Future<dynamic> request(String path, {Json? body}) async {
    final uri = Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/$path');
    try {
      final response =
          await (body == null
                  ? client.get(uri)
                  : client.post(
                      uri,
                      headers: {'Content-Type': 'application/json'},
                      body: jsonEncode(body),
                    ))
              .timeout(const Duration(seconds: 30));
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MarketException(
          decoded is Map ? decoded['error'] ?? '行情服务返回异常' : '行情服务返回异常',
        );
      }
      return decoded;
    } on TimeoutException {
      throw const MarketException('行情服务响应超时，请稍后重试。');
    } on http.ClientException {
      throw MarketException(
        '无法连接 $baseUrl。手机请填写电脑局域网 IP，确认同一 Wi-Fi、后端已启动并允许本地网络访问。',
      );
    } on FormatException {
      throw const MarketException('行情接口返回的数据格式无效。');
    }
  }

  @override
  Future<List<MarketAsset>> assets() async =>
      ((await request('v1/assets')) as List)
          .map((row) => MarketAsset(Json.from(row)))
          .toList();
  @override
  Future<MarketSnapshot> snapshot(String symbol) async =>
      MarketSnapshot(Json.from(await request('v1/markets/$symbol')));
  @override
  Future<Json> deliver(
    MarketSnapshot snapshot,
    Forecast forecast,
    int confidence,
    String channel,
  ) async => Json.from(
    await request(
      'v1/deliveries',
      body: {
        'symbol': snapshot.asset.symbol,
        'prediction_id': forecast.id,
        'confidence': confidence,
        'channel': channel,
      },
    ),
  );
  @override
  void close() => client.close();
}

class DemoMarketService extends MarketService {
  Future<Json>? _data;
  Json? _cached;
  Future<Json> payload() async {
    final cached = _cached;
    if (cached != null) return cached;
    return _data ??= rootBundle.loadString('assets/market-demo.json').then((
      value,
    ) {
      final data = Json.from(jsonDecode(value));
      _cached = data;
      return data;
    });
  }

  @override
  Future<List<MarketAsset>> assets() async =>
      ((await payload())['assets'] as List)
          .map((row) => MarketAsset(Json.from(row)))
          .toList();
  @override
  Future<MarketSnapshot> snapshot(String symbol) async =>
      MarketSnapshot((await payload())['snapshots'][symbol]);
  @override
  Future<Json> deliver(
    MarketSnapshot snapshot,
    Forecast forecast,
    int confidence,
    String channel,
  ) async => {
    'id': 'local-${DateTime.now().microsecondsSinceEpoch}',
    'asset_name': snapshot.asset.name,
    'symbol': snapshot.asset.symbol,
    'prediction_id': forecast.id,
    'created_at': DateTime.now().toUtc().toIso8601String(),
    'channel': channel,
    'forecast': {
      'horizon': forecast.horizon,
      'confidence': confidence,
      'lower': forecast.last.lower(confidence),
      'upper': forecast.last.upper(confidence),
      'median': forecast.last.median,
      'decimals': snapshot.asset.decimals,
      'explanation': forecast.explanation,
      'market_source': 'mock',
      'as_of': snapshot.asOf,
    },
  };
}
