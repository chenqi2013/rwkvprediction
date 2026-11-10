import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_request_log.dart';
import 'market_service.dart';
import 'models.dart';
import 'minute_models.dart';

class MarketController extends ChangeNotifier {
  MarketController(
    this.preferences, {
    MarketService? service,
    ApiRequestLog? requestLog,
  }) : requestLog = requestLog ?? ApiRequestLog(),
       dark = preferences.getBool('dark') ?? true,
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
  }
  static const defaultBaseUrl = 'http://218.17.184.73:8787';

  final SharedPreferences preferences;
  final ApiRequestLog requestLog;
  late MarketService _service;
  bool dark;
  String get baseUrl => defaultBaseUrl;
  bool demo;
  Set<String> favorites;
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
  bool loading = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;
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
    _service.cancelPending();
    notifyListeners();
    try {
      if (_disposed || generation != _generation) return;
      final updatedSnapshot = await _service.snapshot(requested);
      if (_disposed || generation != _generation) return;
      if (updatedSnapshot.asset.id != requested &&
          updatedSnapshot.asset.symbol != requested) {
        throw const MarketException('接口返回的标的与请求不一致。');
      }
      snapshot = updatedSnapshot;
      symbol = updatedSnapshot.asset.id;
      final assetIndex = assets.indexWhere((item) => item.id == symbol);
      if (assetIndex < 0) {
        assets.insert(0, updatedSnapshot.asset);
      } else {
        assets[assetIndex] = updatedSnapshot.asset;
      }
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

  Future<MinuteSnapshot> minutes(
    String identity, {
    String? date,
    bool includeMarket = false,
  }) => _service.minutes(identity, date: date, includeMarket: includeMarket);

  Future<void> setDark(bool value) async {
    dark = value;
    notifyListeners();
    await preferences.setBool('dark', value);
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

  Future<void> configure({required bool useDemo}) async {
    ++_generation;
    _service.close();
    demo = useDemo;
    _service = _makeService();
    snapshot = null;
    if (useDemo) symbol = '510300';
    await load();
  }

  @override
  void dispose() {
    _disposed = true;
    _service.close();
    requestLog.dispose();
    super.dispose();
  }
}
