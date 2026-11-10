import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'market_controller.dart';
import 'minute_models.dart';
import 'models.dart';
import 'rwkv_forecast_panel.dart';
import 'theme.dart';

class MinuteMarketPage extends StatefulWidget {
  const MinuteMarketPage({
    super.key,
    required this.controller,
    required this.instrument,
  });
  final MarketController controller;
  final MarketInstrument instrument;

  @override
  State<MinuteMarketPage> createState() => _MinuteMarketPageState();
}

class _MinuteMarketPageState extends State<MinuteMarketPage> {
  late MarketInstrument instrument = widget.instrument;
  MinuteSnapshot? snapshot;
  String? date;
  String? error;
  bool loading = false;
  bool includeMarket = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.controller.minutes(
        instrument.id,
        date: date,
        includeMarket: includeMarket,
      );
      if (!mounted || generation != request) return;
      if (result.instrument.id != instrument.id ||
          (date != null && result.date != date)) {
        throw const FormatException('分钟行情与请求的标的或日期不一致');
      }
      setState(() => snapshot = result);
    } catch (exception) {
      if (mounted && generation == request) {
        setState(() => error = exception.toString());
      }
    } finally {
      if (mounted && generation == request) setState(() => loading = false);
    }
  }

  Future<void> selectInstrument() async {
    final selected = await showSearch<MarketInstrument?>(
      context: context,
      delegate: _MinuteSearch(widget.controller),
    );
    if (selected == null || !mounted) return;
    setState(() {
      instrument = selected;
      date = null;
      snapshot = null;
      includeMarket = false;
    });
    await load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    final current = snapshot;
    return Scaffold(
      appBar: AppBar(
        title: const Text('分钟行情'),
        actions: [
          IconButton(
            tooltip: '搜索分钟行情标的',
            onPressed: selectInstrument,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: '刷新分钟行情',
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextButton.icon(
                        onPressed: selectInstrument,
                        icon: const Icon(Icons.swap_horiz),
                        label: Text(
                          '${instrument.name} · ${instrument.symbol} · 切换标的',
                        ),
                      ),
                      if (loading) const LinearProgressIndicator(),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Column(
                            children: [
                              Text(
                                '${current == null ? '' : '刷新失败，保留原行情。'}$error',
                                style: TextStyle(color: colors.orange),
                              ),
                              TextButton(
                                onPressed: loading ? null : load,
                                child: const Text('重新加载'),
                              ),
                            ],
                          ),
                        ),
                      if (current != null) ...[
                        MarketPanel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 20,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    current.bars.last.close.toStringAsFixed(
                                      current.decimals,
                                    ),
                                    style: const TextStyle(
                                      fontSize: 32,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  DropdownButton<String>(
                                    key: const ValueKey('minute-date'),
                                    value: date ?? current.date,
                                    items: [
                                      const DropdownMenuItem(
                                        value: null,
                                        child: Text('最近可用交易日'),
                                      ),
                                      ...current.availableDates.map(
                                        (day) => DropdownMenuItem(
                                          value: day,
                                          child: Text(day),
                                        ),
                                      ),
                                    ],
                                    onChanged: loading
                                        ? null
                                        : (value) {
                                            setState(() {
                                              date = value;
                                              snapshot = null;
                                            });
                                            load();
                                          },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${current.vendor} · 1 分钟 · 不复权\n数据截至 ${current.date} ${current.bars.last.time}（北京时间）${current.date != current.availableDates.first
                                    ? ' · 历史行情'
                                    : current.stale
                                    ? ' · 最近可用数据'
                                    : ''}',
                                style: TextStyle(
                                  color: colors.secondary,
                                  fontSize: 12,
                                  height: 1.6,
                                ),
                              ),
                              const SizedBox(height: 12),
                              MinutePriceChart(snapshot: current),
                              const SizedBox(height: 8),
                              Text(
                                '拖动或悬停查看 OHLC 与成交量；缺失分钟和午休不连接。',
                                style: TextStyle(
                                  color: colors.secondary,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        MarketPanel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'RWKV 分钟输入',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '当日共 ${current.bars.length} 根分钟线，截止点连续片段 ${current.readiness['context_bars']} 根；可在下方选择历史预测起点。',
                              ),
                              const SizedBox(height: 8),
                              ...List<String>.from(
                                current.readiness['reasons'],
                              ).map(
                                (reason) => Text(
                                  '• $reason',
                                  style: TextStyle(
                                    color: colors.secondary,
                                    height: 1.6,
                                  ),
                                ),
                              ),
                              if (instrument.kind == '股票' &&
                                  ['sh', 'sz'].contains(instrument.market))
                                TextButton.icon(
                                  key: const ValueKey('prepare-minute-market'),
                                  onPressed: loading
                                      ? null
                                      : () {
                                          includeMarket = true;
                                          load();
                                        },
                                  icon: const Icon(Icons.dataset_outlined),
                                  label: Text(
                                    current.market == null
                                        ? '加载同期市场统计'
                                        : '刷新行情与市场统计',
                                  ),
                                ),
                              if (current.market != null) ...[
                                Text(
                                  '固定实验集合 ${current.market!['size']} 只，已加载 ${current.market!['loaded_count']} 只。',
                                ),
                                const Text('尚未核对训练集合，统计值仅用于输入流程验证。'),
                              ],
                              const SizedBox(height: 8),
                              Text(
                                '截止点不满足输入条件时，可在下方选择较早的有效起点；预测需要至少 65 根完整分钟线和同期市场统计。',
                                style: TextStyle(
                                  color: colors.secondary,
                                  height: 1.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (instrument.kind == '股票' &&
                            ['sh', 'sz'].contains(instrument.market)) ...[
                          const SizedBox(height: 12),
                          RwkvForecastPanel(snapshot: current),
                        ],
                        for (final warning in current.warnings)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              warning,
                              style: TextStyle(
                                color: colors.secondary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MinuteSearch extends SearchDelegate<MarketInstrument?> {
  _MinuteSearch(this.controller) : super(searchFieldLabel: '搜索股票、ETF 或指数');
  final MarketController controller;
  @override
  List<Widget> buildActions(BuildContext context) => [
    IconButton(onPressed: () => query = '', icon: const Icon(Icons.clear)),
  ];
  @override
  Widget buildLeading(BuildContext context) =>
      BackButton(onPressed: () => close(context, null));
  @override
  Widget buildResults(BuildContext context) => results(context);
  @override
  Widget buildSuggestions(BuildContext context) => query.trim().isEmpty
      ? ListView(
          children: controller.assets
              .map((asset) => tile(context, asset))
              .toList(),
        )
      : results(context);
  Widget tile(BuildContext context, MarketInstrument asset) => ListTile(
    title: Text(asset.name),
    subtitle: Text('${asset.symbol} · ${asset.kind}'),
    onTap: () => close(context, asset),
  );
  Widget results(BuildContext context) => FutureBuilder<InstrumentSearch>(
    key: ValueKey(query),
    future: controller.search(query.trim()),
    builder: (context, value) {
      if (value.hasError) return Center(child: Text('${value.error}'));
      if (!value.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      if (value.data!.items.isEmpty) return const Center(child: Text('没有找到标的'));
      return ListView(
        children: [
          ...value.data!.warnings.map(
            (warning) => ListTile(subtitle: Text(warning)),
          ),
          ...value.data!.items.map((asset) => tile(context, asset)),
        ],
      );
    },
  );
}

class MinutePriceChart extends StatefulWidget {
  const MinutePriceChart({super.key, required this.snapshot});
  final MinuteSnapshot snapshot;
  @override
  State<MinutePriceChart> createState() => _MinutePriceChartState();
}

class _MinutePriceChartState extends State<MinutePriceChart> {
  int? selected;
  @override
  void didUpdateWidget(covariant MinutePriceChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot != widget.snapshot) selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final colors = MarketColors.of(context);
    final point = selected == null
        ? snapshot.bars.last
        : snapshot.bars[selected!];
    String price(double? value) =>
        value?.toStringAsFixed(snapshot.decimals) ?? '缺失';
    return LayoutBuilder(
      builder: (context, constraints) {
        void select(Offset position) {
          final minute =
              ((position.dx - 8) / math.max(1, constraints.maxWidth - 16) * 330)
                  .clamp(0, 330);
          var closest = 0;
          var distance = double.infinity;
          for (var i = 0; i < snapshot.bars.length; i++) {
            final time = DateTime.parse(snapshot.bars[i].timestamp);
            final difference = (time.hour * 60 + time.minute - 570 - minute)
                .abs();
            if (difference < distance) {
              distance = difference.toDouble();
              closest = i;
            }
          }
          setState(() => selected = closest);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${point.time} · 收 ${price(point.close)}  开 ${price(point.open)}  高 ${price(point.high)}  低 ${price(point.low)}\n成交量 ${point.volume.toStringAsFixed(0)} ${snapshot.shares ? '股' : '原始单位'}${point.amount == null ? '' : ' · 成交额 ${point.amount!.toStringAsFixed(0)} 元'}',
              key: const ValueKey('minute-chart-inspection'),
              style: const TextStyle(fontSize: 11, height: 1.7),
            ),
            const SizedBox(height: 10),
            MouseRegion(
              cursor: SystemMouseCursors.precise,
              onHover: (event) => select(event.localPosition),
              child: GestureDetector(
                onTapDown: (event) => select(event.localPosition),
                onHorizontalDragStart: (event) => select(event.localPosition),
                onHorizontalDragUpdate: (event) => select(event.localPosition),
                child: SizedBox(
                  height: 240,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _MinutePainter(snapshot, colors, selected),
                  ),
                ),
              ),
            ),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('09:30', style: TextStyle(fontSize: 10)),
                Text('11:30   午休   13:00', style: TextStyle(fontSize: 10)),
                Text('15:00', style: TextStyle(fontSize: 10)),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _MinutePainter extends CustomPainter {
  _MinutePainter(this.snapshot, this.colors, this.selected);
  final MinuteSnapshot snapshot;
  final MarketColors colors;
  final int? selected;
  @override
  void paint(Canvas canvas, Size size) {
    final bars = snapshot.bars;
    final low = bars.map((bar) => bar.close).reduce(math.min);
    final high = bars.map((bar) => bar.close).reduce(math.max);
    final span = math.max(high - low, high * .002);
    final center = (high + low) / 2;
    double x(MinuteBar bar) {
      final time = DateTime.parse(bar.timestamp);
      return 8 + (time.hour * 60 + time.minute - 570) / 330 * (size.width - 16);
    }

    double y(MinuteBar bar) =>
        size.height * .4 - (bar.close - center) / span * size.height * .65;
    final grid = Paint()
      ..color = colors.line
      ..strokeWidth = .7;
    for (var i = 0; i < 4; i++) {
      final top = size.height * i / 4;
      canvas.drawLine(Offset(0, top), Offset(size.width, top), grid);
    }
    canvas.drawRect(
      Rect.fromLTRB(
        size.width * 120 / 330,
        0,
        size.width * 210 / 330,
        size.height,
      ),
      Paint()..color = colors.line.withValues(alpha: .25),
    );
    final path = Path();
    final maxVolume = math.max(
      1,
      bars.map((bar) => bar.volume).reduce(math.max),
    );
    for (var i = 0; i < bars.length; i++) {
      final bar = bars[i];
      final previous = i == 0 ? null : bars[i - 1];
      if (previous == null ||
          previous.session != bar.session ||
          DateTime.parse(
                bar.timestamp,
              ).difference(DateTime.parse(previous.timestamp)).inMinutes !=
              1) {
        path.moveTo(x(bar), y(bar));
      } else {
        path.lineTo(x(bar), y(bar));
      }
      // Also draw isolated bars that have no connecting segment.
      canvas.drawCircle(
        Offset(x(bar), y(bar)),
        1,
        Paint()..color = colors.blue,
      );
      canvas.drawLine(
        Offset(x(bar), size.height),
        Offset(
          x(bar),
          size.height - bar.volume / maxVolume * size.height * .15,
        ),
        Paint()
          ..color = colors.blue.withValues(alpha: .5)
          ..strokeWidth = 1.5,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    if (selected != null) {
      final point = bars[selected!];
      canvas.drawLine(
        Offset(x(point), 0),
        Offset(x(point), size.height),
        Paint()
          ..color = colors.orange
          ..strokeWidth = 1,
      );
      canvas.drawCircle(
        Offset(x(point), y(point)),
        3,
        Paint()..color = colors.orange,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MinutePainter oldDelegate) =>
      oldDelegate.snapshot != snapshot ||
      oldDelegate.selected != selected ||
      oldDelegate.colors.dark != colors.dark;
}
