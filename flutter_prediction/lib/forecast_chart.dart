import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';

class ForecastChart extends StatefulWidget {
  const ForecastChart({
    super.key,
    required this.snapshot,
    required this.forecast,
    required this.confidence,
    this.historicalOnly = false,
    this.height = 230,
  });
  final MarketSnapshot snapshot;
  final Forecast forecast;
  final int confidence;
  final bool historicalOnly;
  final double height;
  @override
  State<ForecastChart> createState() => _ForecastChartState();
}

class _ForecastChartState extends State<ForecastChart> {
  double? selected;
  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(constraints.maxWidth - 54, 1.0);
        final split = widget.historicalOnly ? width : width * .49;
        String? date;
        String? value;
        if (selected != null) {
          if (selected! <= split || widget.historicalOnly) {
            final index =
                (selected! / split * (widget.snapshot.history.length - 1))
                    .round()
                    .clamp(0, widget.snapshot.history.length - 1);
            final point = widget.snapshot.history[index];
            date = '${point.date} · 历史';
            value = widget.snapshot.asset.format(point.close);
          } else {
            final index =
                ((selected! - split) /
                            (width - split) *
                            widget.forecast.points.length -
                        1)
                    .round()
                    .clamp(0, widget.forecast.points.length - 1);
            final point = widget.forecast.points[index];
            date = '${point.date} · 模拟预测';
            value =
                '${widget.snapshot.asset.format(point.lower(widget.confidence))} – ${widget.snapshot.asset.format(point.upper(widget.confidence))}';
          }
        }
        void select(Offset position) =>
            setState(() => selected = position.dx.clamp(0, width));
        return Semantics(
          label:
              '${widget.snapshot.asset.name}历史走势${widget.historicalOnly ? '' : '与未来${widget.forecast.horizon}日模拟预测，${widget.confidence}%期末区间${widget.snapshot.asset.format(widget.forecast.last.lower(widget.confidence))}至${widget.snapshot.asset.format(widget.forecast.last.upper(widget.confidence))}'}',
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            onHover: (event) => select(event.localPosition),
            onExit: (_) => setState(() => selected = null),
            child: GestureDetector(
              onTapDown: (details) => select(details.localPosition),
              onTapUp: (_) => setState(() => selected = null),
              onHorizontalDragStart: (details) => select(details.localPosition),
              onHorizontalDragUpdate: (details) =>
                  select(details.localPosition),
              onHorizontalDragEnd: (_) => setState(() => selected = null),
              onHorizontalDragCancel: () => setState(() => selected = null),
              child: SizedBox(
                height: widget.height,
                width: double.infinity,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _ChartPainter(
                          snapshot: widget.snapshot,
                          forecast: widget.forecast,
                          confidence: widget.confidence,
                          historicalOnly: widget.historicalOnly,
                          colors: colors,
                          selected: selected,
                        ),
                      ),
                    ),
                    if (date != null)
                      Positioned(
                        left: (selected! - 88).clamp(
                          0,
                          math.max(0, constraints.maxWidth - 192),
                        ),
                        top: 27,
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: colors.selected,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: colors.line),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  date,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colors.secondary,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  value!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.snapshot,
    required this.forecast,
    required this.confidence,
    required this.historicalOnly,
    required this.colors,
    this.selected,
  });
  final MarketSnapshot snapshot;
  final Forecast forecast;
  final int confidence;
  final bool historicalOnly;
  final MarketColors colors;
  final double? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final width = math.max(1.0, size.width - 54);
    final height = math.max(1.0, size.height - 54);
    const top = 26.0;
    final split = historicalOnly ? width : width * .49;
    final values = [
      ...snapshot.history.map((point) => point.close),
      if (!historicalOnly)
        ...forecast.points.expand(
          (point) => [point.lower(confidence), point.upper(confidence)],
        ),
    ];
    final low = values.reduce(math.min);
    final high = values.reduce(math.max);
    final padding = math.max((high - low) * .15, .001);
    final lower = low - padding;
    final upper = high + padding;
    double ordinate(double price) =>
        top + height * (1 - (price - lower) / (upper - lower));
    void label(
      String text,
      Offset position,
      Color color, {
      bool alignRight = false,
      double fontSize = 10,
    }) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei'],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          alignRight ? position.dx - painter.width : position.dx,
          position.dy,
        ),
      );
    }

    for (var index = 0; index <= 4; index++) {
      final gridY = top + height * index / 4;
      dashed(
        canvas,
        Path()
          ..moveTo(0, gridY)
          ..lineTo(width, gridY),
        colors.line,
        .8,
      );
      label(
        snapshot.asset.format(upper - (upper - lower) * index / 4),
        Offset(size.width, gridY - 6),
        colors.secondary,
        alignRight: true,
      );
    }
    final current = Offset(split, ordinate(snapshot.asset.price));
    List<Offset> future(String key) => [
      current,
      ...forecast.points.indexed.map(
        (entry) => Offset(
          split + (width - split) * (entry.$1 + 1) / forecast.points.length,
          ordinate(entry.$2.value(key)),
        ),
      ),
    ];
    if (!historicalOnly) {
      final outerUpper = future(confidence == 95 ? 'p975' : 'p90');
      final outerLower = future(confidence == 95 ? 'p025' : 'p10');
      final area = band(outerUpper, outerLower);
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            colors: [
              colors.orange.withValues(alpha: .05),
              colors.orange.withValues(alpha: .22),
            ],
          ).createShader(Rect.fromLTRB(split, top, width, height + top)),
      );
      canvas.drawPath(
        band(future('p75'), future('p25')),
        Paint()..color = colors.orange.withValues(alpha: .16),
      );
      dashed(canvas, path(outerUpper), colors.orange.withValues(alpha: .5), .9);
      dashed(canvas, path(outerLower), colors.orange.withValues(alpha: .5), .9);
      dashed(canvas, path(future('p50')), colors.orange, 2);
      dashed(
        canvas,
        Path()
          ..moveTo(split, 20)
          ..lineTo(split, height + top),
        colors.secondary.withValues(alpha: .45),
        .8,
      );
      label('预测区间', Offset(split + (width - split) / 2 - 20, 2), colors.orange);
      label(
        '当前',
        Offset(split - 10, height + top + 10),
        colors.secondary,
        fontSize: 9,
      );
    }
    final history = snapshot.history.indexed
        .map(
          (entry) => Offset(
            split * entry.$1 / math.max(snapshot.history.length - 1, 1),
            ordinate(entry.$2.close),
          ),
        )
        .toList();
    canvas.drawPath(
      path(history),
      Paint()
        ..color = colors.blue
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(current, 6, Paint()..color = colors.surface);
    canvas.drawCircle(current, 3.5, Paint()..color = colors.blue);
    label(
      shortDate(snapshot.history.first.date),
      Offset(0, height + top + 10),
      colors.secondary,
    );
    label(
      shortDate(
        historicalOnly ? snapshot.history.last.date : forecast.last.date,
      ),
      Offset(width, height + top + 10),
      colors.secondary,
      alignRight: true,
    );
    if (selected != null) {
      dashed(
        canvas,
        Path()
          ..moveTo(selected!, top)
          ..lineTo(selected!, height + top),
        colors.ink.withValues(alpha: .5),
        1,
      );
    }
  }

  Path path(List<Offset> points) => Path()..addPolygon(points, false);
  Path band(List<Offset> upper, List<Offset> lower) =>
      Path()..addPolygon([...upper, ...lower.reversed], true);
  void dashed(Canvas canvas, Path path, Color color, double width) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 7) {
        canvas.drawPath(
          metric.extractPath(distance, math.min(distance + 4, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) =>
      oldDelegate.snapshot != snapshot ||
      oldDelegate.forecast != forecast ||
      oldDelegate.confidence != confidence ||
      oldDelegate.selected != selected ||
      oldDelegate.historicalOnly != historicalOnly ||
      oldDelegate.colors.dark != colors.dark;
}
