typedef Json = Map<String, dynamic>;

double number(dynamic value) => (value as num).toDouble();
String signed(double value, [int digits = 2]) =>
    '${value >= 0 ? '+' : ''}${value.toStringAsFixed(digits)}';
String shortDate(String value) =>
    value.length >= 10 ? value.substring(5, 10).replaceAll('-', '/') : value;

class MarketInstrument {
  MarketInstrument(this.json);
  final Json json;
  String get symbol => json['symbol'];
  String get name => json['name'];
  String get kind => json['kind'];
  String get subtitle => json['subtitle'];
  String get market =>
      json['market'] ??
      (kind == '指数'
          ? (symbol.startsWith('399') ? 'sz' : 'sh')
          : (symbol.startsWith('5') || symbol.startsWith('6')
                ? 'sh'
                : RegExp(r'^[489]').hasMatch(symbol)
                ? 'bj'
                : 'sz'));
  String get id =>
      json['id'] ??
      '$market-${{'ETF': 'etf', '指数': 'index', '股票': 'stock'}[kind]}-$symbol';
  Json get metadata => {
    'id': id,
    'symbol': symbol,
    'name': name,
    'kind': kind,
    'market': market,
    'subtitle': subtitle,
  };
}

class InstrumentSearch {
  InstrumentSearch(Json json)
    : items = (json['items'] as List)
          .map((row) => MarketInstrument(Json.from(row)))
          .toList(),
      total = json['total'],
      hasMore = json['has_more'],
      warnings = List<String>.from(json['warnings'] ?? []);
  final List<MarketInstrument> items;
  final int total;
  final bool hasMore;
  final List<String> warnings;
}

class MarketAsset extends MarketInstrument {
  MarketAsset(super.json);
  double get price => number(json['price']);
  double get changePercent => number(json['change_percent']);
  double get previousClose => number(json['previous_close']);
  double get change => price - previousClose;
  int get decimals => kind == 'ETF' ? 3 : 2;
  String format(double value) => value.toStringAsFixed(decimals);
  String percent(double target) => '${signed((target / price - 1) * 100)}%';
}

class HistoryPoint {
  HistoryPoint(Json json) : date = json['date'], close = number(json['close']);
  final String date;
  final double close;
}

class ForecastPoint {
  ForecastPoint(this.json);
  final Json json;
  String get date => json['date'];
  double value(String key) => number(json[key]);
  double lower(int confidence) => value(confidence == 95 ? 'p025' : 'p10');
  double upper(int confidence) => value(confidence == 95 ? 'p975' : 'p90');
  double get median => value('p50');
}

class Forecast {
  Forecast(this.json)
    : points = (json['points'] as List)
          .map((point) => ForecastPoint(Json.from(point)))
          .toList() {
    if (points.isEmpty) throw const FormatException('预测区间为空');
    for (final point in points) {
      final values = [
        'p025',
        'p10',
        'p25',
        'p50',
        'p75',
        'p90',
        'p975',
      ].map(point.value).toList();
      for (var index = 0; index < values.length; index++) {
        if (!values[index].isFinite ||
            values[index] <= 0 ||
            (index > 0 && values[index] < values[index - 1])) {
          throw const FormatException('预测区间数据无效');
        }
      }
    }
  }
  final Json json;
  final List<ForecastPoint> points;
  String get id => json['id'];
  int get horizon => json['horizon'];
  ForecastPoint get last => points.last;
  String get trend => json['trend'];
  String get explanation => json['explanation'];
  double get upProbability => number(json['up_probability']);
  List<Json> get drivers =>
      (json['drivers'] as List).map((row) => Json.from(row)).toList();
  List<Json> get scenarios =>
      (json['scenarios'] as List).map((row) => Json.from(row)).toList();
  Json get backtest => json['backtest'];
  Json get usage => json['usage'];
}

class MarketSnapshot {
  MarketSnapshot(Json json)
    : asset = MarketAsset(json['asset']),
      asOf = json['as_of'],
      source = json['source'],
      vendor = json['market_vendor'],
      history = (json['history'] as List)
          .map((row) => HistoryPoint(Json.from(row)))
          .toList(),
      predictions = (json['predictions'] as Json).map(
        (key, value) => MapEntry(int.parse(key), Forecast(Json.from(value))),
      ) {
    if (history.isEmpty ||
        ![5, 20, 60].every(predictions.containsKey) ||
        history.any((point) => !point.close.isFinite || point.close <= 0)) {
      throw const FormatException('行情数据不完整');
    }
  }
  final MarketAsset asset;
  final String asOf;
  final String source;
  final String? vendor;
  final List<HistoryPoint> history;
  final Map<int, Forecast> predictions;
  bool get isLive => source == 'akshare';
  String get sourceLabel => isLive ? 'AKShare · 日线收盘' : '模拟行情 · 离线演示';
  String get description => isLive
      ? '行情来自 AKShare${vendor == 'sina' ? '（新浪备用源）' : ''}，展示最近完整交易日收盘。${vendor == 'sina' && asset.kind == '指数' ? '备用源暂无指数成交额。' : ''}预测、解读与回测均为模拟，尚未接入 RWKV。'
      : '离线演示：行情、预测、解读与回测均为模拟数据。';
}
