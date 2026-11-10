import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';

class HistoryChart extends StatefulWidget {
  const HistoryChart({super.key, required this.snapshot, this.height = 230});
  final MarketSnapshot snapshot;
  final double height;
  @override
  State<HistoryChart> createState() => _HistoryChartState();
}

class _HistoryChartState extends State<HistoryChart> {
  double? selected;
  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(constraints.maxWidth - 54, 1.0);
        final split = width;
        String? date;
        String? value;
        if (selected != null) {
          final index =
              (selected! / split * (widget.snapshot.history.length - 1))
                  .round()
                  .clamp(0, widget.snapshot.history.length - 1);
          final point = widget.snapshot.history[index];
          date = '${point.date} · 历史';
          value = widget.snapshot.asset.format(point.close);
        }
        void select(Offset position) =>
            setState(() => selected = position.dx.clamp(0, width));
        return Semantics(
          label: '${widget.snapshot.asset.name}历史走势',
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
  _ChartPainter({required this.snapshot, required this.colors, this.selected});
  final MarketSnapshot snapshot;
  final MarketColors colors;
  final double? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final width = math.max(1.0, size.width - 54);
    final height = math.max(1.0, size.height - 54);
    const top = 26.0;
    final split = width;
    final values = [...snapshot.history.map((point) => point.close)];
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
            fontFamily: 'Roboto',
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
      shortDate(snapshot.history.last.date),
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
      oldDelegate.selected != selected ||
      oldDelegate.colors.dark != colors.dark;
}
