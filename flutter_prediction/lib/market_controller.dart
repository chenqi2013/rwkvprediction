import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'market_service.dart';
import 'models.dart';

class MarketController extends ChangeNotifier {
  MarketController(this.preferences, {MarketService? service})
    : dark = preferences.getBool('dark') ?? true,
      baseUrl = preferences.getString('baseUrl') ?? defaultBaseUrl,
      demo = const bool.fromEnvironment('DEMO_MODE'),
      favorites = (preferences.getStringList('favorites') ?? []).toSet() {
    _service = service ?? _makeService();
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
  late MarketService _service;
  bool dark;
  String baseUrl;
  bool demo;
  Set<String> favorites;
  List<Json> deliveries = [];
  List<MarketAsset> assets = [];
  MarketSnapshot? snapshot;
  String symbol = '510300';
  int horizon = 20;
  int confidence = 80;
  bool loading = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;
  Forecast? get forecast => snapshot?.predictions[horizon];
  MarketService _makeService() =>
      demo ? DemoMarketService() : HttpMarketService(baseUrl);
  Future<void> load({String? selectedSymbol}) async {
    final generation = ++_generation;
    if (selectedSymbol != null) symbol = selectedSymbol;
    if (snapshot?.asset.symbol != symbol) snapshot = null;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final updatedAssets = await _service.assets();
      if (_disposed || generation != _generation) return;
      final updatedSnapshot = await _service.snapshot(symbol);
      if (_disposed || generation != _generation) return;
      if (updatedSnapshot.asset.symbol != symbol) {
        throw const MarketException('接口返回的标的与请求不一致。');
      }
      assets = updatedAssets;
      snapshot = updatedSnapshot;
    } catch (exception) {
      if (!_disposed && generation == _generation) error = exception.toString();
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

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

  Future<void> toggleFavorite(String value) async {
    if (!favorites.add(value)) favorites.remove(value);
    notifyListeners();
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
    assets = [];
    snapshot = null;
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
    super.dispose();
  }
}
