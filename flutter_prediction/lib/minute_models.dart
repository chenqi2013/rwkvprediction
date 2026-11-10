import 'models.dart';

class MinuteBar {
  MinuteBar(Json json)
    : timestamp = json['timestamp'],
      session = json['session'],
      open = json['open'] == null ? null : number(json['open']),
      high = number(json['high']),
      low = number(json['low']),
      close = number(json['close']),
      volume = number(json['volume']),
      amount = json['amount'] == null ? null : number(json['amount']) {
    final time = DateTime.tryParse(timestamp);
    if (time == null ||
        time.second != 0 ||
        ![high, low, close, volume, ?open, ?amount].every((v) => v.isFinite) ||
        low <= 0 ||
        close < low ||
        close > high ||
        (open != null && (open! < low || open! > high)) ||
        volume < 0 ||
        (amount != null && amount! < 0)) {
      throw const FormatException('分钟行情数据无效');
    }
  }
  final String timestamp;
  final String session;
  final double? open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final double? amount;
  String get time => timestamp.substring(11, 16);
}

class MinuteSnapshot {
  MinuteSnapshot(this.json)
    : instrument = MarketInstrument(Json.from(json['instrument'])),
      bars = (json['bars'] as List)
          .map((row) => MinuteBar(Json.from(row)))
          .toList() {
    if (json['granularity'] != '1m' ||
        json['timezone'] != 'Asia/Shanghai' ||
        json['price_adjustment'] != 'none' ||
        bars.isEmpty ||
        bars.any((bar) => !bar.timestamp.startsWith(date))) {
      throw const FormatException('分钟行情不完整');
    }
    for (var index = 1; index < bars.length; index++) {
      if (bars[index].timestamp.compareTo(bars[index - 1].timestamp) <= 0) {
        throw const FormatException('分钟行情时间必须严格递增');
      }
    }
    if (DateTime.parse(json['as_of']).toUtc() !=
        DateTime.parse('${bars.last.timestamp}:00+08:00').toUtc()) {
      throw const FormatException('分钟行情截止时间不一致');
    }
  }
  final Json json;
  final MarketInstrument instrument;
  final List<MinuteBar> bars;
  String get date => json['date'];
  List<String> get availableDates => List<String>.from(json['available_dates']);
  List<String> get warnings => List<String>.from(json['warnings'] ?? []);
  Json get readiness => Json.from(json['rwkv_input']);
  Json? get market => json['market_statistics'] == null
      ? null
      : Json.from(json['market_statistics']);
  bool get stale => json['stale'] == true;
  bool get shares => json['volume_unit'] == 'share';
  String get vendor => json['market_vendor'] == 'sina' ? '新浪' : '东方财富';
  int get decimals => instrument.kind == 'ETF' ? 3 : 2;
}
