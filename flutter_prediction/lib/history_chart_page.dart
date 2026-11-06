import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'forecast_chart.dart';
import 'models.dart';
import 'theme.dart';

bool usesMobileHistoryLayout(BuildContext context) =>
    switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };

class HistoryChartPage extends StatelessWidget {
  const HistoryChartPage({
    super.key,
    required this.snapshot,
    required this.forecast,
    required this.confidence,
  });

  final MarketSnapshot snapshot;
  final Forecast forecast;
  final int confidence;

  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    final mobile = usesMobileHistoryLayout(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: colors.surface,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => RotatedBox(
                key: const ValueKey('landscape-history'),
                quarterTurns:
                    mobile && constraints.maxHeight > constraints.maxWidth
                    ? 1
                    : 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            tooltip: mobile ? '退出横屏' : '退出全屏查看（Esc）',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '${snapshot.asset.name} ${snapshot.asset.symbol} · 历史行情',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '近 ${snapshot.history.length} 个交易日',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.secondary,
                            ),
                          ),
                        ],
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) => ForecastChart(
                            snapshot: snapshot,
                            forecast: forecast,
                            confidence: confidence,
                            historicalOnly: true,
                            height: constraints.maxHeight,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          const SizedBox(width: 12),
                          Container(width: 12, height: 2, color: colors.blue),
                          const SizedBox(width: 6),
                          Text(
                            '收盘价格 · CNY',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.secondary,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            mobile ? '拖动图表查看日期与价格' : '鼠标悬停查看日期与价格 · Esc 返回',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.secondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
