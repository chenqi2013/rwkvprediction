import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_request_log.dart';
import 'market_service.dart';
import 'models.dart';

class MarketController extends ChangeNotifier {
  MarketController(
    this.preferences, {
    MarketService? service,
    ApiRequestLog? requestLog,
  }) : requestLog = requestLog ?? ApiRequestLog(),
       dark = preferences.getBool('dark') ?? true,
       baseUrl = preferences.getString('baseUrl') ?? defaultBaseUrl,
       demo = const bool.fromEnvironment('DEMO_MODE'),
       favorites = (preferences.getStringList('favorites') ?? []).toSet() {
    _service = service ?? _makeService();
    if (_service is HttpMarketService) {
      (_service as HttpMarketService).requestLog = this.requestLog;
    }
    favorites = favorites.map(legacyIdentity).toSet();
    try {
      final saved =
          jsonDecode(preferences.getString('instruments') ?? '[]') as List;
      for (final row in saved) {
        final asset = MarketInstrument(Json.from(row));
        assets.removeWhere((item) => item.id == asset.id);
        assets.add(asset);
      }
    } on FormatException {
      preferences.remove('instruments');
    }
    try {
      deliveries =
          (jsonDecode(preferences.getString('deliveries') ?? '[]') as List)
              .map((value) => Json.from(value))
              .toList();
    } on FormatException {
      deliveries = [];
    }
  }
  static String get defaultBaseUrl {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) return configured;
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:8787'
        : 'http://127.0.0.1:8787';
  }

  final SharedPreferences preferences;
  final ApiRequestLog requestLog;
  late MarketService _service;
  bool dark;
  String baseUrl;
  bool demo;
  Set<String> favorites;
  List<Json> deliveries = [];
  static String legacyIdentity(String value) => switch (value) {
    '000001' || '000300' => 'sh-index-$value',
    '510300' || '588000' => 'sh-etf-$value',
    '159915' => 'sz-etf-$value',
    _ => value,
  };
  List<MarketInstrument> assets = [
    for (final row in [
      ['510300', '沪深300ETF', 'ETF', '上交所'],
      ['159915', '创业板ETF', 'ETF', '深交所'],
      ['588000', '科创50ETF', 'ETF', '上交所'],
      ['000300', '沪深300', '指数', '上交所'],
      ['000001', '上证指数', '指数', '上交所'],
    ])
      MarketInstrument({
        'symbol': row[0],
        'name': row[1],
        'kind': row[2],
        'subtitle': row[3],
      }),
  ];
  MarketSnapshot? snapshot;
  String symbol = '510300';
  int horizon = 20;
  int confidence = 80;
  bool loading = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;
  Forecast? get forecast => snapshot?.predictions[horizon];
  MarketService _makeService() => demo
      ? DemoMarketService()
      : HttpMarketService(baseUrl, requestLog: requestLog);
  Future<void> load({String? selectedSymbol}) async {
    final generation = ++_generation;
    if (selectedSymbol != null) symbol = selectedSymbol;
    final requested = symbol;
    if (snapshot?.asset.id != requested &&
        snapshot?.asset.symbol != requested) {
      snapshot = null;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final updatedSnapshot = await _service.snapshot(requested);
      if (_disposed || generation != _generation) return;
      if (updatedSnapshot.asset.id != requested &&
          updatedSnapshot.asset.symbol != requested) {
        throw const MarketException('接口返回的标的与请求不一致。');
      }
      snapshot = updatedSnapshot;
      symbol = updatedSnapshot.asset.id;
      assets.removeWhere((item) => item.id == symbol);
      assets.insert(0, updatedSnapshot.asset);
      await preferences.setString(
        'instruments',
        jsonEncode(assets.map((asset) => asset.metadata).toList()),
      );
    } catch (exception) {
      if (!_disposed && generation == _generation) error = exception.toString();
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<InstrumentSearch> search(
    String query, {
    String? kind,
    int offset = 0,
  }) => _service.search(query, kind: kind, offset: offset);

  Future<void> setDark(bool value) async {
    dark = value;
    notifyListeners();
    await preferences.setBool('dark', value);
  }

  void setHorizon(int value) {
    horizon = value;
    notifyListeners();
  }

  void setConfidence(int value) {
    confidence = value;
    notifyListeners();
  }

  Future<void> toggleFavorite(
    String value, {
    MarketInstrument? instrument,
  }) async {
    value = legacyIdentity(value);
    final added = favorites.add(value);
    if (!added) favorites.remove(value);
    final rememberInstrument =
        added &&
        instrument != null &&
        !assets.any((asset) => asset.id == value);
    if (rememberInstrument) assets.add(instrument);
    notifyListeners();
    if (rememberInstrument) {
      await preferences.setString(
        'instruments',
        jsonEncode(assets.map((asset) => asset.metadata).toList()),
      );
    }
    await preferences.setStringList('favorites', favorites.toList());
  }

  Future<void> configure(String address, bool useDemo) async {
    final uri = Uri.tryParse(address.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const MarketException(
        '请输入有效的 HTTP 或 HTTPS 地址，例如 http://192.168.1.89:8787',
      );
    }
    ++_generation;
    _service.close();
    baseUrl = address.trim().replaceFirst(RegExp(r'/+$'), '');
    demo = useDemo;
    _service = _makeService();
    snapshot = null;
    if (useDemo) symbol = '510300';
    await preferences.setString('baseUrl', baseUrl);
    await load();
  }

  Future<Json> deliver(String channel) async {
    final current = snapshot;
    final prediction = forecast;
    if (current == null || prediction == null) {
      throw const MarketException('请先加载行情');
    }
    final receipt = await _service.deliver(
      current,
      prediction,
      confidence,
      channel,
    );
    deliveries.insert(0, receipt);
    await preferences.setString('deliveries', jsonEncode(deliveries));
    if (!_disposed) notifyListeners();
    return receipt;
  }

  @override
  void dispose() {
    _disposed = true;
    _service.close();
    requestLog.dispose();
    super.dispose();
  }
}
