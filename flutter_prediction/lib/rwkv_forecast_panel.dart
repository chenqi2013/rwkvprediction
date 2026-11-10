import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import 'minute_models.dart';
import 'rwkv_forecast.dart';
import 'rwkv_model.dart';
import 'theme.dart';

class RwkvForecastPanel extends StatefulWidget {
  const RwkvForecastPanel({super.key, required this.snapshot, this.model});
  final MinuteSnapshot snapshot;
  final RwkvModel? model;
  @override
  State<RwkvForecastPanel> createState() => _RwkvForecastPanelState();
}

class _RwkvForecastPanelState extends State<RwkvForecastPanel> {
  late final model = widget.model ?? RwkvModel();
  late List<String> origins = rwkvOrigins(widget.snapshot);
  String? origin;
  RwkvForecast? forecast;
  String? error;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    origin = origins.lastOrNull;
    model.addListener(changed);
    model.initialize();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant RwkvForecastPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot != widget.snapshot) {
      ++generation;
      origins = rwkvOrigins(widget.snapshot);
      final sameSelection =
          oldWidget.snapshot.instrument.id == widget.snapshot.instrument.id &&
          oldWidget.snapshot.date == widget.snapshot.date;
      if (!sameSelection || !origins.contains(origin)) {
        origin = origins.lastOrNull;
      }
      final previous = forecast;
      if (previous != null) {
        try {
          final features = prepareRwkvFeatures(
            widget.snapshot,
            previous.origin,
          );
          final hash = sha256.convert(features.buffer.asUint8List()).toString();
          if (!sameSelection ||
              previous.inputHash != hash ||
              previous.universeId != widget.snapshot.market?['universe_id']) {
            forecast = null;
          }
        } catch (_) {
          forecast = null;
        }
      }
      error = null;
    }
  }

  Future<void> run() async {
    final selected = origin;
    if (selected == null) return;
    final request = ++generation;
    setState(() {
      error = null;
      forecast = null;
    });
    try {
      final value = await model.predict(widget.snapshot, selected);
      if (mounted && request == generation) setState(() => forecast = value);
    } catch (e) {
      if (mounted && request == generation) setState(() => error = '$e');
    }
  }

  @override
  void dispose() {
    ++generation;
    model.removeListener(changed);
    if (widget.model == null) model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final colors = MarketColors.of(context);
    final replay = origin != null && origin != snapshot.bars.last.timestamp;
    return MarketPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'RWKV 分钟预测 · 实验版',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(model.status),
          if (model.busy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(value: model.progress),
            ),
          if (!model.ready)
            Wrap(
              spacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: model.busy ? null : () => model.install(),
                  icon: const Icon(Icons.download),
                  label: const Text('下载 RWKV 模型'),
                ),
                if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
                  TextButton(
                    onPressed: model.busy
                        ? null
                        : () async {
                            final path = await getDirectoryPath(
                              confirmButtonText: '导入模型',
                            );
                            if (path != null && mounted) {
                              await model.install(sourceDirectory: path);
                            }
                          },
                    child: const Text('导入模型目录'),
                  ),
              ],
            ),
          if (model.error != null)
            Text(model.error!, style: TextStyle(color: colors.orange)),
          const SizedBox(height: 10),
          if (origins.isEmpty)
            const Text('暂无可用预测起点：需要同一时段从起始分钟开始的至少 65 根完整分钟线，且剩余交易时间不少于 30 分钟。')
          else ...[
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('预测起点（北京时间）'),
                DropdownButton<String>(
                  key: const ValueKey('rwkv-origin'),
                  value: origin,
                  items: origins
                      .map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text(v.substring(11, 16)),
                        ),
                      )
                      .toList(),
                  onChanged: model.busy
                      ? null
                      : (v) => setState(() {
                          ++generation;
                          origin = v;
                          forecast = null;
                          error = null;
                        }),
                ),
                FilledButton.icon(
                  key: const ValueKey('run-rwkv-forecast'),
                  onPressed:
                      !model.ready || model.busy || snapshot.market == null
                      ? null
                      : run,
                  icon: const Icon(Icons.auto_graph),
                  label: Text(replay ? '运行历史起点预测' : '预测未来 30 分钟'),
                ),
              ],
            ),
            if (snapshot.market == null) const Text('请先点击上方「加载同期市场统计」，再运行预测。'),
            Text(
              replay
                  ? '历史回放：仅使用 $origin 及之前的数据推理，之后的真实行情仅用于对照。'
                  : '预测使用当前数据截止点之前的行情；刷新后可查看已发生的真实价格。',
              style: TextStyle(color: colors.secondary, height: 1.6),
            ),
          ],
          if (error != null)
            Text(error!, style: TextStyle(color: colors.orange)),
          if (forecast case final value?) ...[
            const SizedBox(height: 16),
            RwkvForecastChart(snapshot: snapshot, forecast: value),
            const SizedBox(height: 8),
            Text(
              '本设备 C++ CPU · 含权重加载 ${value.latencyMs} ms · 64×23 输入 → 30×9 分位数',
              style: TextStyle(color: colors.secondary, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '预测使用 8 只实验股票的同期统计，尚未核对训练集合及官方 CUDA 数值；区间覆盖率未经校准，仅供研究。',
            style: TextStyle(
              color: colors.secondary,
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class RwkvForecastChart extends StatelessWidget {
  const RwkvForecastChart({
    super.key,
    required this.snapshot,
    required this.forecast,
  });
  final MinuteSnapshot snapshot;
  final RwkvForecast forecast;
  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    final origin = minuteTime(forecast.origin);
    final prices = forecast.prices;
    final actual = <int, double>{
      for (final bar in snapshot.bars)
        if (minuteTime(bar.timestamp).isAfter(origin) &&
            minuteTime(bar.timestamp).difference(origin).inMinutes <= 30)
          minuteTime(bar.timestamp).difference(origin).inMinutes: bar.close,
    };
    final errors = [
      for (final entry in actual.entries)
        (prices[entry.key - 1][4] - entry.value).abs(),
    ];
    final baseline = [
      for (final price in actual.values) (forecast.anchor - price).abs(),
    ];
    final hits60 = actual.entries
        .where(
          (v) =>
              v.value >= prices[v.key - 1][1] &&
              v.value <= prices[v.key - 1][7],
        )
        .length;
    final hits80 = actual.entries
        .where(
          (v) =>
              v.value >= prices[v.key - 1][0] &&
              v.value <= prices[v.key - 1][8],
        )
        .length;
    final last = prices.last;
    String price(double v) => v.toStringAsFixed(snapshot.decimals + 1);
    Widget chart(bool history) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          history ? '历史与预测 · 元' : '未来 30 分钟放大 · 元',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 240,
          width: double.infinity,
          child: CustomPaint(
            painter: _ForecastPainter(snapshot, forecast, colors, history),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 50, top: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                history
                    ? rwkvPrefix(snapshot, forecast.origin).first.time
                    : forecast.origin.substring(11, 16),
                style: const TextStyle(fontSize: 10),
              ),
              Text(
                minuteLabel(
                  origin.add(const Duration(minutes: 30)),
                ).substring(11, 16),
                style: const TextStyle(fontSize: 10),
              ),
            ],
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '+30 分钟中位数 ${price(last[4])} · 60% 区间 ${price(last[1])}～${price(last[7])} · 80% 区间 ${price(last[0])}～${price(last[8])}',
          key: const ValueKey('rwkv-forecast-summary'),
          style: const TextStyle(height: 1.6),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 800
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: chart(true)),
                    const SizedBox(width: 24),
                    Expanded(child: chart(false)),
                  ],
                )
              : Column(
                  children: [
                    chart(true),
                    const SizedBox(height: 20),
                    chart(false),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            Text('━ 真实价格', style: TextStyle(color: colors.blue)),
            Text('━ 预测中位数', style: TextStyle(color: colors.orange)),
            Text('━ 起点价格', style: TextStyle(color: colors.secondary)),
            Text('▰ 60% / 80% 逐分钟预测区间', style: TextStyle(color: colors.blue)),
          ],
        ),
        const SizedBox(height: 10),
        if (actual.isEmpty)
          const Text('后续真实行情尚未返回，暂不计算对照指标。')
        else
          Text(
            '已对照 ${actual.length}/30 分钟 · 中位数 MAE ${(errors.reduce((a, b) => a + b) / errors.length).toStringAsFixed(4)} 元 · 维持现价 MAE ${(baseline.reduce((a, b) => a + b) / baseline.length).toStringAsFixed(4)} 元\n本窗口覆盖：60% 区间 ${(hits60 / actual.length * 100).toStringAsFixed(1)}% · 80% 区间 ${(hits80 / actual.length * 100).toStringAsFixed(1)}%（单个窗口不代表整体准确率）',
            style: const TextStyle(fontSize: 12, height: 1.6),
          ),
      ],
    );
  }
}

class _ForecastPainter extends CustomPainter {
  _ForecastPainter(this.snapshot, this.forecast, this.colors, this.history);
  final MinuteSnapshot snapshot;
  final RwkvForecast forecast;
  final MarketColors colors;
  final bool history;
  @override
  void paint(Canvas canvas, Size size) {
    final origin = minuteTime(forecast.origin);
    final start = history
        ? minuteTime(rwkvPrefix(snapshot, forecast.origin).first.timestamp)
        : origin;
    final end = origin.add(const Duration(minutes: 30));
    final actual = snapshot.bars
        .where(
          (b) =>
              !minuteTime(b.timestamp).isBefore(start) &&
              !minuteTime(b.timestamp).isAfter(end),
        )
        .toList();
    final prices = forecast.prices;
    final values = [
      forecast.anchor,
      ...prices.expand((row) => [row.first, row.last]),
      ...actual.map((b) => b.close),
    ];
    final low = values.reduce(math.min), high = values.reduce(math.max);
    final span = math.max(high - low, forecast.anchor * .001);
    final bottom = (high + low - span) / 2 - span * .07;
    final top = (high + low + span) / 2 + span * .07;
    double x(DateTime t) =>
        52 +
        t.difference(start).inMinutes /
            end.difference(start).inMinutes *
            math.max(1, size.width - 58);
    double y(double p) => 6 + (top - p) / (top - bottom) * (size.height - 12);
    for (var i = 0; i < 5; ++i) {
      final value = bottom + (top - bottom) * i / 4;
      final height = y(value);
      canvas.drawLine(
        Offset(50, height),
        Offset(size.width, height),
        Paint()
          ..color = colors.line
          ..strokeWidth = .7,
      );
      final label = TextPainter(
        text: TextSpan(
          text: value.toStringAsFixed(snapshot.decimals + 1),
          style: TextStyle(fontSize: 9, color: colors.secondary),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 48);
      label.paint(canvas, Offset(0, height - label.height / 2));
    }
    void band(int lo, int hi, double opacity) {
      final path = Path()..moveTo(x(origin), y(forecast.anchor));
      for (var i = 0; i < 30; ++i) {
        path.lineTo(x(origin.add(Duration(minutes: i + 1))), y(prices[i][hi]));
      }
      for (var i = 29; i >= 0; --i) {
        path.lineTo(x(origin.add(Duration(minutes: i + 1))), y(prices[i][lo]));
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()..color = colors.blue.withValues(alpha: opacity),
      );
    }

    band(0, 8, .12);
    band(1, 7, .22);
    canvas.drawLine(
      Offset(x(origin), y(forecast.anchor)),
      Offset(x(end), y(forecast.anchor)),
      Paint()
        ..color = colors.secondary
        ..strokeWidth = 1.2,
    );
    for (double dy = 0; dy < size.height; dy += 8) {
      canvas.drawLine(
        Offset(x(origin), dy),
        Offset(x(origin), math.min(size.height, dy + 4)),
        Paint()..color = colors.secondary,
      );
    }
    final median = Path()..moveTo(x(origin), y(forecast.anchor));
    for (var i = 0; i < 30; ++i) {
      median.lineTo(x(origin.add(Duration(minutes: i + 1))), y(prices[i][4]));
    }
    canvas.drawPath(
      median,
      Paint()
        ..color = colors.orange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7,
    );
    final real = Path();
    for (var i = 0; i < actual.length; ++i) {
      final bar = actual[i];
      final t = minuteTime(bar.timestamp);
      if (i == 0 ||
          t.difference(minuteTime(actual[i - 1].timestamp)).inMinutes != 1) {
        real.moveTo(x(t), y(bar.close));
      } else {
        real.lineTo(x(t), y(bar.close));
      }
      canvas.drawCircle(
        Offset(x(t), y(bar.close)),
        1,
        Paint()..color = colors.blue,
      );
    }
    canvas.drawPath(
      real,
      Paint()
        ..color = colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _ForecastPainter old) =>
      old.snapshot != snapshot ||
      old.forecast != forecast ||
      old.history != history ||
      old.colors.dark != colors.dark;
}
