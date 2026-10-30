import 'package:flutter/material.dart';

import 'forecast_chart.dart';
import 'market_controller.dart';
import 'models.dart';
import 'sheets.dart';
import 'theme.dart';

class MarketPage extends StatefulWidget {
  const MarketPage({super.key, required this.controller});
  final MarketController controller;
  @override
  State<MarketPage> createState() => _MarketPageState();
}

class _MarketPageState extends State<MarketPage> {
  MarketController get model => widget.controller;
  int section = 1;
  final scrollController = ScrollController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) model.load();
    });
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  void show(Widget child) => showMarketSheet(context, child);
  void assets({bool favoritesOnly = false}) =>
      show(AssetPicker(controller: model, favoritesOnly: favoritesOnly));
  void setSection(int value) {
    setState(() => section = value);
    if (scrollController.hasClients) scrollController.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: colors.surface,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1240),
                  child: _navigation(context),
                ),
              ),
            ),
            if (model.loading)
              LinearProgressIndicator(
                minHeight: 2,
                color: colors.orange,
                backgroundColor: colors.line,
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (MediaQuery.sizeOf(context).width >= 1100)
                    _watchlist(sidebar: true),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: model.load,
                      color: colors.orange,
                      child: Scrollbar(
                        controller: scrollController,
                        child: ListView(
                          controller: scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 1240,
                                ),
                                child: model.snapshot != null
                                    ? _content(context)
                                    : _empty(context),
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
            _bottomBar(context),
          ],
        ),
      ),
    );
  }

  Widget _navigation(BuildContext context) {
    final colors = MarketColors.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Icon(
            Icons.stacked_line_chart_rounded,
            color: colors.orange,
            size: 28,
          ),
          const SizedBox(width: 8),
          const Text(
            '知势',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          if (wide) ...[
            const SizedBox(width: 10),
            Text(
              'RWKV · 市场预测',
              style: TextStyle(color: colors.secondary, fontSize: 12),
            ),
          ],
          const SizedBox(width: 20),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Tooltip(
                  message: '搜索 ETF、指数和股票',
                  child: InkWell(
                    onTap: assets,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: colors.canvas,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search, color: colors.secondary, size: 19),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              wide ? '搜索名称 / 代码' : '搜索标的',
                              style: TextStyle(
                                color: colors.secondary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '下发记录',
            onPressed: () => show(HistorySheet(controller: model)),
            icon: Badge(
              isLabelVisible: model.deliveries.isNotEmpty,
              smallSize: 5,
              backgroundColor: colors.orange,
              child: const Icon(Icons.notifications_none_rounded, size: 22),
            ),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () => show(SettingsSheet(controller: model)),
            icon: const Icon(Icons.settings_outlined, size: 21),
          ),
        ],
      ),
    );
  }

  Widget _watchlist({bool sidebar = false}) {
    final colors = MarketColors.of(context);
    // Only display metadata here: unrequested instruments have no current quote.
    final items = model.assets.take(12).toList();
    Widget entry(MarketInstrument asset) {
      final selected = model.snapshot?.asset.id == asset.id;
      return InkWell(
        key: ValueKey('quick-${asset.id}'),
        onTap: () => model.load(selectedSymbol: asset.id),
        child: Container(
          width: sidebar ? null : 136,
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: sidebar ? 15 : 10,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.orangeSoft : Colors.transparent,
            border: sidebar
                ? Border(
                    left: BorderSide(
                      color: selected ? colors.orange : Colors.transparent,
                      width: 3,
                    ),
                  )
                : Border(
                    bottom: BorderSide(
                      color: selected ? colors.orange : Colors.transparent,
                      width: 2,
                    ),
                  ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      asset.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: selected ? colors.orange : colors.ink,
                      ),
                    ),
                  ),
                  if (sidebar && model.favorites.contains(asset.id))
                    Icon(Icons.star_rounded, size: 14, color: colors.orange),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${asset.market.toUpperCase()} ${asset.symbol}',
                style: TextStyle(fontSize: 10, color: colors.secondary),
              ),
            ],
          ),
        ),
      );
    }

    if (!sidebar) {
      return Container(
        color: colors.surface,
        height: 62,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: items.map(entry).toList(),
        ),
      );
    }
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '最近浏览',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '查看我的自选',
                  onPressed: () => assets(favoritesOnly: true),
                  icon: Icon(
                    Icons.star_border_rounded,
                    size: 19,
                    color: colors.orange,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: ListView(children: items.map(entry).toList())),
          TextButton.icon(
            onPressed: assets,
            icon: const Icon(Icons.add, size: 17),
            label: const Text('添加 / 搜索标的'),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final colors = MarketColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 100),
      child: Column(
        children: [
          if (model.loading) ...[
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text('正在加载市场数据…', style: TextStyle(color: colors.secondary)),
          ] else ...[
            Icon(Icons.wifi_off_rounded, size: 50, color: colors.secondary),
            const SizedBox(height: 20),
            const Text(
              '暂时无法加载行情',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              model.error ?? '请稍后重试',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.secondary, height: 1.7),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: model.load,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
            TextButton(
              onPressed: () => show(SettingsSheet(controller: model)),
              child: const Text('设置行情服务地址'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final snapshot = model.snapshot!;
    final forecast = model.forecast!;
    final colors = MarketColors.of(context);
    return Column(
      children: [
        if (MediaQuery.sizeOf(context).width < 1100) _watchlist(),
        _quote(snapshot),
        Container(
          color: colors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Row(
            children: ['行情', 'AI 预测', '市场解读'].indexed
                .map(
                  (entry) => InkWell(
                    onTap: () => setSection(entry.$1),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 30, top: 12),
                      child: Column(
                        children: [
                          Text(
                            entry.$2,
                            style: TextStyle(
                              fontSize: 15,
                              color: section == entry.$1
                                  ? colors.ink
                                  : colors.secondary,
                              fontWeight: section == entry.$1
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: 25,
                            height: 3,
                            decoration: BoxDecoration(
                              color: section == entry.$1
                                  ? colors.orange
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        if (model.error != null)
          Container(
            color: colors.orangeSoft,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '刷新失败，保留原行情：${model.error}',
                    style: TextStyle(fontSize: 11, color: colors.orange),
                  ),
                ),
                TextButton(
                  onPressed: model.loading ? null : model.load,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final left = Column(
              children: [
                if (section == 0)
                  _history(snapshot, forecast)
                else if (section == 1)
                  _forecast(snapshot, forecast)
                else
                  _insight(forecast, expanded: true),
                const SizedBox(height: 8),
                if (section == 0)
                  _marketDetails(snapshot.asset)
                else
                  _scenarios(snapshot.asset, forecast),
                if (!wide && section != 0) ...[
                  const SizedBox(height: 8),
                  if (section == 1) _insight(forecast),
                  if (section == 1) const SizedBox(height: 8),
                  _evaluation(forecast),
                ],
              ],
            );
            return Padding(
              padding: EdgeInsets.all(wide ? 12 : 0),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 8, child: left),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 5,
                          child: Column(
                            children: [
                              if (section == 1)
                                _insight(forecast)
                              else if (section == 0)
                                _insight(forecast),
                              if (section != 2) const SizedBox(height: 8),
                              _evaluation(forecast),
                            ],
                          ),
                        ),
                      ],
                    )
                  : left,
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(
            children: [
              Text(
                '${snapshot.sourceLabel}  ·  预测模拟',
                style: TextStyle(
                  color: colors.secondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${snapshot.description}\n概率区间不代表收益保证，不构成投资建议。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.secondary,
                  fontSize: 10,
                  height: 1.7,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _quote(MarketSnapshot snapshot) {
    final colors = MarketColors.of(context);
    final asset = snapshot.asset;
    final priceColor = asset.changePercent >= 0 ? colors.red : colors.green;
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: assets,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              asset.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 18,
                            color: colors.secondary,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${asset.market.toUpperCase()}  ${asset.symbol}  ${asset.subtitle}',
                        style: TextStyle(fontSize: 11, color: colors.secondary),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: model.favorites.contains(asset.id) ? '移出自选' : '加入自选',
                onPressed: () => model.toggleFavorite(asset.id),
                icon: Icon(
                  model.favorites.contains(asset.id)
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  color: model.favorites.contains(asset.id)
                      ? colors.orange
                      : colors.secondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        asset.format(asset.price),
                        style: TextStyle(
                          fontSize: 40,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w600,
                          letterSpacing: -1.3,
                          color: priceColor,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 10,
                      runSpacing: 2,
                      children: [
                        Text(
                          signed(asset.change, asset.decimals),
                          style: TextStyle(fontSize: 12, color: priceColor),
                        ),
                        Text(
                          '${signed(asset.changePercent)}%',
                          style: TextStyle(fontSize: 12, color: priceColor),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 6,
                child: Column(
                  children: [
                    Row(
                      children: [
                        _quoteStat(
                          '最高',
                          asset.format(number(asset.json['high'])),
                        ),
                        _quoteStat(
                          '今开',
                          asset.format(number(asset.json['open'])),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _quoteStat(
                          '最低',
                          asset.format(number(asset.json['low'])),
                        ),
                        _quoteStat('昨收', asset.format(asset.previousClose)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _quoteStat('成交额', asset.json['volume'].toString()),
                        _quoteStat('币种', 'CNY'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: colors.secondary,
                  shape: BoxShape.circle,
                ),
              ),
              Text(
                '${snapshot.isLive ? '日线收盘' : '演示收盘'} · ${shortDate(snapshot.asOf)} 15:00',
                style: TextStyle(fontSize: 10, color: colors.secondary),
              ),
              Text(
                snapshot.sourceLabel,
                style: TextStyle(fontSize: 10, color: colors.secondary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quoteStat(String label, String value) {
    final colors = MarketColors.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 11, color: colors.secondary),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _forecast(MarketSnapshot snapshot, Forecast forecast) {
    final colors = MarketColors.of(context);
    final asset = snapshot.asset;
    final trendColor = forecast.last.median >= asset.price
        ? colors.red
        : colors.green;
    return MarketPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '走势预测',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              const MarketBadge('RWKV', icon: Icons.graphic_eq),
              const Spacer(),
              IconButton(
                tooltip: '预测方法与区间说明',
                visualDensity: VisualDensity.compact,
                onPressed: () => show(MethodSheet(snapshot: snapshot)),
                icon: Icon(
                  Icons.info_outline,
                  size: 18,
                  color: colors.secondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Icon(Icons.sync, size: 12, color: colors.secondary),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '数据截至 ${snapshot.asOf.substring(0, 10).replaceAll('-', '/')} 15:00',
                  style: TextStyle(fontSize: 10, color: colors.secondary),
                ),
              ),
              Text(
                '模拟预测',
                style: TextStyle(color: colors.orange, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: colors.canvas,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  children: [5, 20, 60]
                      .map(
                        (days) => InkWell(
                          key: ValueKey('horizon-$days'),
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => model.setHorizon(days),
                          child: Container(
                            width: 46,
                            height: 29,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: model.horizon == days
                                  ? colors.selected
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '$days日',
                              style: TextStyle(
                                fontSize: 12,
                                color: model.horizon == days
                                    ? colors.ink
                                    : colors.secondary,
                                fontWeight: model.horizon == days
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const Spacer(),
              PopupMenuButton<int>(
                tooltip: '预测区间',
                initialValue: model.confidence,
                onSelected: model.setConfidence,
                itemBuilder: (_) => [80, 95]
                    .map(
                      (value) => PopupMenuItem(
                        value: value,
                        child: Text('$value% 预测区间'),
                      ),
                    )
                    .toList(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        '${model.confidence}% 区间',
                        style: TextStyle(fontSize: 11, color: colors.secondary),
                      ),
                      Icon(
                        Icons.keyboard_arrow_down,
                        size: 15,
                        color: colors.secondary,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 17),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Icon(
                forecast.last.median >= asset.price
                    ? Icons.trending_up
                    : Icons.trending_down,
                size: 17,
                color: trendColor,
              ),
              Text(
                forecast.trend,
                style: TextStyle(
                  color: trendColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '│',
                style: TextStyle(color: trendColor.withValues(alpha: .4)),
              ),
              Text(
                '上涨概率  ${(forecast.upProbability * 100).toStringAsFixed(0)}%',
                style: TextStyle(color: trendColor, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ForecastChart(
            snapshot: snapshot,
            forecast: forecast,
            confidence: model.confidence,
          ),
          _legends(),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
            decoration: BoxDecoration(
              color: colors.canvas,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _metric(
                    '区间下沿',
                    asset.format(forecast.last.lower(model.confidence)),
                    detail: asset.percent(
                      forecast.last.lower(model.confidence),
                    ),
                    color: colors.green,
                  ),
                ),
                Container(width: 1, height: 36, color: colors.line),
                Expanded(
                  child: _metric(
                    '中位预期',
                    asset.format(forecast.last.median),
                    detail: asset.percent(forecast.last.median),
                    color: colors.orange,
                  ),
                ),
                Container(width: 1, height: 36, color: colors.line),
                Expanded(
                  child: _metric(
                    '区间上沿',
                    asset.format(forecast.last.upper(model.confidence)),
                    detail: asset.percent(
                      forecast.last.upper(model.confidence),
                    ),
                    color: colors.red,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              Icon(Icons.schedule, size: 12, color: colors.secondary),
              const SizedBox(width: 6),
              Text(
                '未来 ${forecast.horizon} 个交易日 · 期末价格区间',
                style: TextStyle(fontSize: 10, color: colors.secondary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(String title, String value, {String? detail, Color? color}) {
    final colors = MarketColors.of(context);
    return Column(
      children: [
        Text(title, style: TextStyle(fontSize: 10, color: colors.secondary)),
        const SizedBox(height: 7),
        FittedBox(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(detail, style: TextStyle(fontSize: 10, color: color)),
        ],
      ],
    );
  }

  Widget _legends({bool historicalOnly = false}) {
    final colors = MarketColors.of(context);
    Widget legend(String label, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 11,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: colors.secondary)),
      ],
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        legend('历史走势', colors.blue),
        if (!historicalOnly) ...[
          const SizedBox(width: 16),
          legend('中位走势', colors.orange),
          const SizedBox(width: 16),
          legend(
            '${model.confidence}% 区间',
            colors.orange.withValues(alpha: .4),
          ),
        ],
      ],
    );
  }

  Widget _insight(Forecast forecast, {bool expanded = false}) {
    final colors = MarketColors.of(context);
    return MarketPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_outlined, color: colors.orange, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '读懂这次预测',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              if (!expanded)
                TextButton(
                  onPressed: () => setSection(2),
                  child: Text(
                    '完整解读 ›',
                    style: TextStyle(fontSize: 10, color: colors.secondary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            forecast.explanation,
            style: TextStyle(fontSize: 12, color: colors.body, height: 1.9),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: forecast.drivers.indexed.map((entry) {
              final color = entry.$1 == 2 ? colors.orange : colors.green;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .07),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '● ${entry.$2['title']} ${entry.$2['value']}',
                  style: TextStyle(fontSize: 9, color: color),
                ),
              );
            }).toList(),
          ),
          if (expanded) ...[
            const SizedBox(height: 8),
            const Divider(),
            ...forecast.drivers.map(
              (driver) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            driver['title'],
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Text(
                          driver['value'],
                          style: TextStyle(color: colors.orange, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      driver['detail'],
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.secondary,
                        height: 1.7,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _scenarios(MarketAsset asset, Forecast forecast) {
    final colors = MarketColors.of(context);
    return MarketPanel(
      child: Column(
        children: [
          PanelTitle(
            '三种市场情景',
            trailing: Text(
              '期末目标 · CNY',
              style: TextStyle(fontSize: 10, color: colors.secondary),
            ),
          ),
          const SizedBox(height: 6),
          ...forecast.scenarios.indexed.map((entry) {
            final scenario = entry.$2;
            final color = [
              colors.red,
              colors.orange,
              colors.green,
            ][entry.$1 % 3];
            final target = number(scenario['target']);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      Container(
                        width: 3,
                        height: 30,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 7,
                              children: [
                                Text(
                                  scenario['name'],
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  '${(number(scenario['probability']) * 100).toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    color: colors.secondary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              scenario['detail'],
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.secondary,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            asset.format(target),
                            style: TextStyle(
                              fontSize: 17,
                              color: color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            asset.percent(target),
                            style: TextStyle(fontSize: 10, color: color),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (entry.$1 < forecast.scenarios.length - 1)
                  Divider(height: 1, color: colors.line),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _evaluation(Forecast forecast) {
    final colors = MarketColors.of(context);
    return MarketPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            '预测表现',
            trailing: Text(
              '模拟回测',
              style: TextStyle(color: colors.secondary, fontSize: 10),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: _metric(
                  '80% 区间覆盖率',
                  '${(number(forecast.backtest['coverage']) * 100).toStringAsFixed(1)}%',
                ),
              ),
              Expanded(
                child: _metric(
                  '中位绝对误差',
                  '${(number(forecast.backtest['median_error']) * 100).toStringAsFixed(1)}%',
                ),
              ),
              Expanded(
                child: _metric('回测样本', '${forecast.backtest['sample_count']}'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            forecast.backtest['description'],
            style: TextStyle(
              color: colors.secondary,
              fontSize: 10,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 8),
          const Divider(),
          InkWell(
            onTap: () => show(CostSheet(usage: forecast.usage)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.memory, size: 16, color: colors.secondary),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '推理用量与成本估算',
                      style: TextStyle(color: colors.secondary, fontSize: 11),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: colors.secondary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _history(MarketSnapshot snapshot, Forecast forecast) => MarketPanel(
    child: Column(
      children: [
        PanelTitle(
          '历史行情',
          trailing: Text(
            '近 ${snapshot.history.length} 个交易日',
            style: TextStyle(
              fontSize: 11,
              color: MarketColors.of(context).secondary,
            ),
          ),
        ),
        const SizedBox(height: 18),
        ForecastChart(
          snapshot: snapshot,
          forecast: forecast,
          confidence: model.confidence,
          historicalOnly: true,
          height: 280,
        ),
        _legends(historicalOnly: true),
      ],
    ),
  );
  Widget _marketDetails(MarketAsset asset) => MarketPanel(
    child: Column(
      children: [
        const PanelTitle('行情概览'),
        const SizedBox(height: 22),
        Row(
          children: ['open', 'high', 'low'].indexed
              .map(
                (entry) => Expanded(
                  child: _metric(
                    ['今开', '最高', '最低'][entry.$1],
                    asset.format(number(asset.json[entry.$2])),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 25),
        Row(
          children: [
            Expanded(child: _metric('昨收', asset.format(asset.previousClose))),
            Expanded(child: _metric('成交额', asset.json['volume'])),
            Expanded(child: _metric('交易币种', 'CNY')),
          ],
        ),
      ],
    ),
  );
  Widget _bottomBar(BuildContext context) {
    final colors = MarketColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.line, width: .6)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1240),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Row(
              children: [
                _navItem(
                  '行情',
                  Icons.candlestick_chart_outlined,
                  () => setSection(0),
                  selected: section == 0,
                ),
                _navItem(
                  '自选',
                  Icons.star_border_rounded,
                  () => assets(favoritesOnly: true),
                ),
                _navItem(
                  '预测',
                  Icons.graphic_eq,
                  () => setSection(1),
                  selected: section == 1,
                ),
                const Spacer(),
                IconButton(
                  tooltip: '刷新行情',
                  onPressed: model.loading ? null : model.load,
                  icon: Icon(Icons.refresh, color: colors.secondary, size: 21),
                ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  onPressed: model.forecast == null || model.loading
                      ? null
                      : () => show(DeliverySheet(controller: model)),
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text(
                    '下发预测',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _navItem(
    String title,
    IconData icon,
    VoidCallback onTap, {
    bool selected = false,
  }) {
    final colors = MarketColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 54,
        height: 46,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 22,
              color: selected ? colors.orange : colors.secondary,
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 9,
                color: selected ? colors.orange : colors.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
