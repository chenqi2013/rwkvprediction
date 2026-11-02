import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'models.dart';

const deviceModelName = 'Qwen2.5-0.5B-Instruct Q4_K_M';
const deviceForecastVersion = 'device-forecast-v1';
const deviceForecastSystem =
    '你是端侧行情实验助手。仅根据历史收盘价和统计量，预测未来5、20、60个交易日的期末收益率。'
    'return_pct单位是百分数，例如1.2表示+1.2%，必须在-50到100之间。'
    'summary用简短中文说明未来可能走势和风险，不得将预估说成已发生收益。'
    '不要编造新闻、资金流、财报或准确率。只输出JSON，键为5、20、60，'
    '每个值包含return_pct数字和summary字符串。';

Json deviceForecastSchema() => {
  'type': 'object',
  'additionalProperties': false,
  'required': ['5', '20', '60'],
  'properties': {
    for (final horizon in [5, 20, 60])
      '$horizon': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['return_pct', 'summary'],
        'properties': {
          'return_pct': {'type': 'number'},
          'summary': {'type': 'string', 'minLength': 8, 'maxLength': 240},
        },
      },
  },
};

Json quoteFeatures(Json quote) {
  final rows = quote['history'] as List;
  if (rows.length < 2 || rows.length > 61) {
    throw const FormatException('端侧推理需要 2–61 个完整交易日');
  }
  final closes = rows.map((row) => number(row['close'])).toList();
  if (closes.any((value) => !value.isFinite || value <= 0)) {
    throw const FormatException('历史收盘价无效');
  }
  final dates = rows.map((row) => row['date'] as String).toList();
  for (var index = 0; index < dates.length; index++) {
    DateTime.parse(dates[index]);
    if (index > 0 && dates[index].compareTo(dates[index - 1]) <= 0) {
      throw const FormatException('历史交易日必须严格递增');
    }
  }
  if ((number(quote['asset']['price']) - closes.last).abs() > .00001) {
    throw const FormatException('报价与历史收盘价不一致');
  }
  final returns = [
    for (var index = 1; index < closes.length; index++)
      math.log(closes[index] / closes[index - 1]),
  ];
  final mean =
      returns.reduce((first, second) => first + second) / returns.length;
  final variance = returns.length > 1
      ? returns
                .map((value) => math.pow(value - mean, 2))
                .reduce((first, second) => first + second) /
            (returns.length - 1)
      : returns.first * returns.first;
  double change(int days) =>
      (closes.last / closes[math.max(0, closes.length - 1 - days)] - 1) * 100;
  double average(int days) {
    final values = closes.skip(math.max(0, closes.length - days)).toList();
    return values.reduce((first, second) => first + second) / values.length;
  }

  return {
    'return_5d_pct': change(5),
    'return_20d_pct': change(20),
    'daily_log_volatility': math.max(math.sqrt(variance), .0001),
    'history_days': rows.length,
    'sma_5': average(5),
    'sma_20': average(20),
  };
}

String deviceForecastInput(Json quote) => jsonEncode({
  'name': quote['asset']['name'],
  'symbol': quote['asset']['symbol'],
  'as_of': quote['as_of'],
  'closing_price': quote['asset']['price'],
  'features': quoteFeatures(quote),
  'recent_closes': (quote['history'] as List)
      .skip(math.max(0, (quote['history'] as List).length - 20))
      .map((row) => {'date': row['date'], 'close': row['close']})
      .toList(),
});

Json parseDeviceEstimates(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map ||
      decoded.length != 3 ||
      !['5', '20', '60'].every(decoded.containsKey)) {
    throw const FormatException('模型缺少完整的 5／20／60 日结果');
  }
  for (final value in decoded.values) {
    if (value is! Map ||
        value['return_pct'] is! num ||
        !(value['return_pct'] as num).isFinite ||
        value['return_pct'] < -50 ||
        value['return_pct'] > 100 ||
        value['summary'] is! String ||
        (value['summary'] as String).trim().length < 8 ||
        (value['summary'] as String).length > 240) {
      throw const FormatException('模型目标收益率或解读无效，未使用模拟结果替代');
    }
  }
  return Json.from(decoded);
}

List<String> futureWeekdays(String lastDate, int count) {
  var day = DateTime.parse(lastDate);
  final result = <String>[];
  while (result.length < count) {
    day = DateTime.utc(day.year, day.month, day.day + 1);
    if (day.weekday <= DateTime.friday) {
      result.add(day.toIso8601String().substring(0, 10));
    }
  }
  return result;
}

double normalCdf(double value) {
  final magnitude = value.abs();
  final coefficient = 1 / (1 + .2316419 * magnitude);
  final polynomial =
      coefficient *
      (.319381530 +
          coefficient *
              (-.356563782 +
                  coefficient *
                      (1.781477937 +
                          coefficient *
                              (-1.821255978 + coefficient * 1.330274429))));
  final tail =
      math.exp(-magnitude * magnitude / 2) /
      math.sqrt(2 * math.pi) *
      polynomial;
  return value >= 0 ? 1 - tail : tail;
}

Json projectDeviceForecast(
  Json quote,
  Json estimates,
  Json usage, {
  String model = deviceModelName,
}) {
  final validated = parseDeviceEstimates(jsonEncode(estimates));
  final features = quoteFeatures(quote);
  final price = number(quote['asset']['price']);
  final sigma = number(features['daily_log_volatility']);
  final fingerprint = sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'quote': quote,
            'estimates': validated,
            'model': model,
            'version': deviceForecastVersion,
          }),
        ),
      )
      .toString()
      .substring(0, 16);
  final predictions = <String, dynamic>{};
  for (final horizon in [5, 20, 60]) {
    final estimate = validated['$horizon'];
    final change = number(estimate['return_pct']);
    final target = math.log(1 + change / 100);
    final dates = futureWeekdays(
      (quote['history'] as List).last['date'],
      horizon,
    );
    final points = <Json>[];
    for (var index = 0; index < horizon; index++) {
      final center = math.log(price) + target * (index + 1) / horizon;
      final spread = sigma * math.sqrt(index + 1);
      points.add({
        'date': dates[index],
        for (final entry in {
          'p025': -1.959964,
          'p10': -1.281552,
          'p25': -.67449,
          'p50': 0.0,
          'p75': .67449,
          'p90': 1.281552,
          'p975': 1.959964,
        }.entries)
          entry.key: math.exp(center + entry.value * spread),
      });
    }
    predictions['$horizon'] = {
      'id':
          'device-${quote['asset']['id'] ?? quote['asset']['symbol']}-$horizon-$fingerprint',
      'horizon': horizon,
      'source': 'on_device',
      'model': model,
      'points': points,
      'target_return_pct': change,
      'trend': change > .5
          ? '偏多'
          : change < -.5
          ? '偏空'
          : '震荡',
      'up_probability': normalCdf(target / (sigma * math.sqrt(horizon))),
      'probability_source': 'historical_volatility_heuristic',
      'interval_source': 'historical_log_return_volatility',
      'explanation':
          '${estimate['summary']}\n本设备 $model 实验输出；区间与上涨概率按历史波动公式估算，未经校准。',
      'drivers': [
        for (final pair in [
          ('近5日涨跌', 'return_5d_pct'),
          ('近20日涨跌', 'return_20d_pct'),
        ])
          {
            'title': pair.$1,
            'value': '${signed(number(features[pair.$2]))}%',
            'detail': '由可用历史收盘价计算，不是模型因子权重。',
            'score': 0,
          },
        {
          'title': '日收益波动',
          'value': '${(sigma * 100).toStringAsFixed(2)}%',
          'detail': '历史日对数收益率标准差，用于未经校准的实验区间。',
          'score': 0,
        },
      ],
      'scenarios': [
        for (final entry in [
          ('上沿情景', .2, 'p90'),
          ('中位情景', .6, 'p50'),
          ('下沿情景', .2, 'p10'),
        ])
          {
            'name': entry.$1,
            'probability': entry.$2,
            'target': points.last[entry.$3],
            'detail': '按实验区间取值；占比为展示设定，未经校准。',
          },
      ],
      'usage': {
        ...usage,
        'source': 'measured',
        'model': model,
        'execution': 'on_device',
        'scope': '本设备一次推理生成全部三个周期，非每个周期各调用一次',
      },
      'backtest': {
        'status': 'not_evaluated',
        'coverage': 0,
        'median_error': 0,
        'sample_count': 0,
        'description': '尚未开展该模型的历史回测；覆盖率与误差暂无实测数据。',
      },
    };
  }
  return {
    ...quote,
    'predictions': predictions,
    'model': model,
    'forecast_source': 'on_device',
    'forecast_method': deviceForecastVersion,
    'generated_at': DateTime.now().toUtc().toIso8601String(),
  };
}

Json deviceReceipt(
  MarketSnapshot snapshot,
  Forecast forecast,
  int confidence,
  String channel,
) => {
  'id': 'device-${DateTime.now().microsecondsSinceEpoch}',
  'asset_name': snapshot.asset.name,
  'symbol': snapshot.asset.symbol,
  'instrument_id': snapshot.asset.id,
  'prediction_id': forecast.id,
  'created_at': DateTime.now().toUtc().toIso8601String(),
  'channel': channel,
  'status': 'saved_locally',
  'forecast': {
    'horizon': forecast.horizon,
    'confidence': confidence,
    'lower': forecast.last.lower(confidence),
    'upper': forecast.last.upper(confidence),
    'median': forecast.last.median,
    'decimals': snapshot.asset.decimals,
    'currency': 'CNY',
    'explanation': forecast.explanation,
    'market_source': snapshot.source,
    'as_of': snapshot.asOf,
    'forecast_source': 'on_device',
    'model': forecast.modelLabel,
    'usage': forecast.usage,
    'forecast_method': deviceForecastVersion,
  },
};
