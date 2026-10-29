import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'api_request_log.dart';
import 'models.dart';

class MarketException implements Exception {
  const MarketException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class MarketService {
  Future<List<MarketAsset>> assets();
  Future<InstrumentSearch> search(String query, {String? kind, int offset = 0});
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
  HttpMarketService(this.baseUrl, {http.Client? client, this.requestLog})
    : client = client ?? http.Client();
  final String baseUrl;
  final http.Client client;
  ApiRequestLog? requestLog;

  Future<dynamic> request(String path, {Json? body}) async {
    final uri = Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/$path');
    final started = DateTime.now().toUtc();
    final elapsed = Stopwatch()..start();
    final bodyText = body == null ? null : jsonEncode(body);
    http.Response? response;
    dynamic decoded;
    String? failure;
    try {
      response =
          await (body == null
                  ? client.get(uri)
                  : client.post(
                      uri,
                      headers: {'Content-Type': 'application/json'},
                      body: bodyText,
                    ))
              .timeout(const Duration(seconds: 30));
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MarketException(
          decoded is Map ? decoded['error'] ?? '行情服务返回异常' : '行情服务返回异常',
        );
      }
      return decoded;
    } on TimeoutException {
      failure = '行情服务响应超时，请稍后重试。';
      throw MarketException(failure);
    } on http.ClientException {
      failure = '无法连接 $baseUrl。手机请填写电脑局域网 IP，确认同一 Wi-Fi、后端已启动并允许本地网络访问。';
      throw MarketException(failure);
    } on FormatException {
      failure = '行情接口返回的数据格式无效。';
      throw MarketException(failure);
    } catch (exception) {
      failure = exception.toString();
      rethrow;
    } finally {
      elapsed.stop();
      await requestLog?.record({
        'schema_version': 1,
        'started_at': started.toIso8601String(),
        'completed_at': DateTime.now().toUtc().toIso8601String(),
        'duration_ms': elapsed.elapsedMilliseconds,
        'request': {
          'method': body == null ? 'GET' : 'POST',
          'url': uri.toString(),
          'path': uri.path,
          'query_parameters': uri.queryParametersAll,
          'headers': {if (body != null) 'Content-Type': 'application/json'},
          'body': bodyText == null ? null : jsonDecode(bodyText),
          'body_text': bodyText,
        },
        'response': response == null
            ? null
            : {
                'status_code': response.statusCode,
                'headers': response.headers,
                'body': decoded,
                'body_text': utf8.decode(
                  response.bodyBytes,
                  allowMalformed: true,
                ),
                'body_base64': base64Encode(response.bodyBytes),
              },
        'error': failure,
        'data_note':
            '实际 HTTP 请求与响应。行情来源以响应 source 为准；预测、解读、回测与用量仍为模拟。离线演示不产生 HTTP 记录。',
      });
    }
  }

  @override
  Future<List<MarketAsset>> assets() async =>
      ((await request('v1/assets')) as List)
          .map((row) => MarketAsset(Json.from(row)))
          .toList();
  @override
  Future<InstrumentSearch> search(
    String query, {
    String? kind,
    int offset = 0,
  }) async {
    final path = Uri(
      path: 'v1/instruments',
      queryParameters: {
        'q': query,
        'kind': ?kind,
        'offset': '$offset',
        'limit': '50',
      },
    );
    return InstrumentSearch(Json.from(await request(path.toString())));
  }

  @override
  Future<MarketSnapshot> snapshot(String symbol) async => MarketSnapshot(
    Json.from(await request('v1/markets/${Uri.encodeComponent(symbol)}')),
  );
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
        'instrument_id': snapshot.asset.id,
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
  Future<InstrumentSearch> search(
    String query, {
    String? kind,
    int offset = 0,
  }) async {
    final matches = (await assets())
        .where(
          (asset) =>
              (kind == null || kind == asset.kind) &&
              (asset.name.toLowerCase().contains(query.toLowerCase()) ||
                  asset.symbol.contains(query)),
        )
        .toList();
    return InstrumentSearch({
      'items': matches
          .skip(offset)
          .take(50)
          .map((asset) => asset.metadata)
          .toList(),
      'total': matches.length,
      'has_more': offset + 50 < matches.length,
      'warnings': ['离线演示仅包含 5 个示例标的，关闭演示后可搜索真实市场。'],
    });
  }

  @override
  Future<MarketSnapshot> snapshot(String symbol) async {
    final data = await payload();
    final candidates = await assets();
    final asset = candidates.firstWhere(
      (asset) => asset.id == symbol || asset.symbol == symbol,
    );
    return MarketSnapshot(data['snapshots'][asset.symbol]);
  }

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
    'instrument_id': snapshot.asset.id,
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
