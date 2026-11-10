// Feature contract ported from the pinned Apache-2.0 processor.
// See native/THIRD_PARTY_NOTICES.md.
import 'dart:math' as math;
import 'dart:typed_data';

import 'minute_models.dart';

DateTime minuteTime(String stamp) =>
    DateTime.parse('${stamp.substring(0, 16)}:00Z');
String minuteLabel(DateTime stamp) => stamp.toIso8601String().substring(0, 16);

/// Complete raw prefix at this origin. Future bars are never used as features.
List<MinuteBar> rwkvPrefix(MinuteSnapshot snapshot, String origin) {
  final end = snapshot.bars.indexWhere((bar) => bar.timestamp == origin);
  if (end < 0) throw const FormatException('预测起点不在行情中');
  var start = end;
  while (start > 0 &&
      snapshot.bars[start - 1].session == snapshot.bars[end].session &&
      minuteTime(snapshot.bars[start].timestamp)
              .difference(minuteTime(snapshot.bars[start - 1].timestamp))
              .inMinutes ==
          1) {
    --start;
  }
  final rows = snapshot.bars.sublist(start, end + 1);
  final first = minuteTime(rows.first.timestamp);
  final last = minuteTime(rows.last.timestamp);
  final firstMinute = first.hour * 60 + first.minute;
  final lastMinute = last.hour * 60 + last.minute;
  if (rows.length < 65 ||
      ![570, 571, 780, 781].contains(firstMinute) ||
      lastMinute + 30 > (lastMinute < 720 ? 690 : 900) ||
      rows.any((bar) => bar.open == null)) {
    throw const FormatException('需要从时段起点开始的至少 65 根完整分钟线，且未来 30 分钟处于同一交易时段');
  }
  return rows;
}

List<String> rwkvOrigins(MinuteSnapshot snapshot) {
  if (snapshot.instrument.kind != '股票' ||
      !['sh', 'sz'].contains(snapshot.instrument.market) ||
      !snapshot.shares) {
    return [];
  }
  return [
    for (final bar in snapshot.bars)
      if (_validPrefix(snapshot, bar.timestamp)) bar.timestamp,
  ];
}

bool _validPrefix(MinuteSnapshot snapshot, String origin) {
  try {
    rwkvPrefix(snapshot, origin);
    return true;
  } on FormatException {
    return false;
  }
}

Float32List prepareRwkvFeatures(MinuteSnapshot snapshot, String origin) {
  if (snapshot.instrument.kind != '股票' ||
      !['sh', 'sz'].contains(snapshot.instrument.market) ||
      !snapshot.shares ||
      snapshot.json['price_adjustment'] != 'none' ||
      !['sina', 'akshare'].contains(snapshot.json['source'])) {
    throw const FormatException('RWKV 仅接受真实沪深 A 股不复权分钟行情');
  }
  final rows = rwkvPrefix(snapshot, origin);
  final points = snapshot.market?['points'] as List?;
  if (points == null) throw const FormatException('请先加载同期市场统计');
  final market = {
    for (final point in points) point['timestamp'] as String: point,
  };
  final encoded = <Float32List>[];
  for (var i = 1; i < rows.length; ++i) {
    final row = rows[i];
    final previous = rows[i - 1];
    final stat = market[row.timestamp];
    if (stat == null || (stat['count'] as num? ?? 0) <= 0) {
      throw const FormatException('完整时段前缀缺少同分钟市场统计');
    }
    final stats = [
      for (final key in [
        'market_return',
        'market_volatility',
        'market_up_fraction',
      ])
        (stat[key] as num?)?.toDouble() ?? double.nan,
    ];
    if (stats.any((v) => !v.isFinite) ||
        stats[1] < 0 ||
        stats[2] < 0 ||
        stats[2] > 1) {
      throw const FormatException('市场统计数值无效');
    }
    encoded.add(
      Float32List.fromList([
        100 * math.log(row.open! / previous.close),
        100 * math.log(row.close / previous.close),
        100 * math.log(row.high / math.max(row.open!, row.close)),
        100 * math.log(math.min(row.open!, row.close) / row.low),
        math.log(1 + row.volume) / 10,
      ]),
    );
  }
  final features = Float32List(64 * 23);
  for (var i = encoded.length - 64; i < encoded.length; ++i) {
    final time = minuteTime(rows[i + 1].timestamp);
    final minute = time.hour * 60 + time.minute;
    final weekday = time.weekday - 1;
    final stat = market[rows[i + 1].timestamp];
    if (stat == null || (stat['count'] as num? ?? 0) <= 0) {
      throw const FormatException('预测输入缺少同分钟市场统计');
    }
    double trailing(int window, double Function(int) value) {
      final left = math.max(0, i + 1 - window);
      var sum = 0.0;
      for (var j = left; j <= i; ++j) {
        sum += value(j);
      }
      return sum / (i + 1 - left);
    }

    final returns = [
      for (final window in [5, 15, 30, 60])
        trailing(window, (j) => encoded[j][1]) * math.min(i + 1, window),
    ];
    final volatility = [
      for (final window in [5, 15, 30, 60])
        math.sqrt(
          math.max(0, trailing(window, (j) => encoded[j][1] * encoded[j][1])),
        ),
    ];
    final reconstructedVolume = trailing(
      60,
      (j) => math.exp(encoded[j][4] * 10) - 1,
    );
    final stats = [
      for (final key in [
        'market_return',
        'market_volatility',
        'market_up_fraction',
      ])
        (stat[key] as num?)?.toDouble() ?? double.nan,
    ];
    if (stats.any((v) => !v.isFinite) ||
        stats[1] < 0 ||
        stats[2] < 0 ||
        stats[2] > 1) {
      throw const FormatException('市场统计数值无效');
    }
    final values = [
      ...encoded[i],
      math.sin(2 * math.pi * minute / 1440),
      math.cos(2 * math.pi * minute / 1440),
      minute >= 780 ? 1.0 : 0.0,
      math.sin(2 * math.pi * weekday / 7),
      math.cos(2 * math.pi * weekday / 7),
      ...returns,
      ...volatility,
      encoded[i][4] * 10 - math.log(1 + reconstructedVolume),
      trailing(60, (j) => encoded[j][1] > 0 ? 1 : 0),
      ...stats,
    ];
    features.setRange(
      (i - encoded.length + 64) * 23,
      (i - encoded.length + 65) * 23,
      values,
    );
  }
  if (features.any((v) => !v.isFinite)) {
    throw const FormatException('分钟特征存在非有限值');
  }
  return features;
}

class RwkvForecast {
  RwkvForecast({
    required this.instrumentId,
    required this.origin,
    required this.anchor,
    required this.raw,
    required this.latencyMs,
    required this.inputHash,
    required this.universeId,
  });
  final String instrumentId;
  final String origin;
  final double anchor;
  final List<double> raw;
  final int latencyMs;
  final String inputHash;
  final String universeId;
  List<List<double>> get prices {
    if (raw.length != 270 ||
        raw.any((v) => !v.isFinite) ||
        !anchor.isFinite ||
        anchor <= 0) {
      throw const FormatException('RWKV 预测输出无效');
    }
    final rows = [
      for (var h = 0; h < 30; ++h)
        (raw.sublist(
          h * 9,
          h * 9 + 9,
        )..sort()).map((v) => anchor * math.exp(v / 100)).toList(),
    ];
    if (rows.expand((r) => r).any((v) => !v.isFinite || v <= 0)) {
      throw const FormatException('RWKV 价格输出无效');
    }
    return rows;
  }
}
