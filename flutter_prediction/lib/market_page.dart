import 'package:flutter/material.dart';

import 'history_chart.dart';
import 'history_chart_page.dart';
import 'market_controller.dart';
import 'models.dart';
import 'minute_market_page.dart';
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
  void minutes() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MinuteMarketPage(
        controller: model,
        instrument: model.snapshot?.asset ?? model.assets.first,
      ),
    ),
  );
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
            key: const ValueKey('minute-market-entry'),
            tooltip: '分钟行情',
            onPressed: minutes,
            icon: const Icon(Icons.timeline, size: 22),
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
            TextButton(onPressed: minutes, child: const Text('查看分钟行情（无需模型）')),
            TextButton(
              onPressed: () => show(SettingsSheet(controller: model)),
              child: const Text('查看行情服务设置'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final snapshot = model.snapshot!;
    final colors = MarketColors.of(context);
    return Column(
      children: [
        if (MediaQuery.sizeOf(context).width < 1100) _watchlist(),
        _quote(snapshot),
        if (model.error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '刷新失败，保留原行情：${model.error}',
              style: TextStyle(color: colors.orange),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              _history(snapshot),
              const SizedBox(height: 8),
              _marketDetails(snapshot.asset),
              const SizedBox(height: 16),
              Text(
                snapshot.description,
                style: TextStyle(color: colors.secondary, fontSize: 12),
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

  Widget _history(MarketSnapshot snapshot) => MarketPanel(
    child: Column(
      children: [
        PanelTitle(
          '历史行情',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '近 ${snapshot.history.length} 个交易日',
                style: TextStyle(
                  fontSize: 11,
                  color: MarketColors.of(context).secondary,
                ),
              ),
              IconButton(
                tooltip: usesMobileHistoryLayout(context) ? '横屏查看' : '全屏查看',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => HistoryChartPage(snapshot: snapshot),
                    fullscreenDialog: true,
                  ),
                ),
                icon: Icon(
                  usesMobileHistoryLayout(context)
                      ? Icons.screen_rotation_rounded
                      : Icons.fullscreen_rounded,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        HistoryChart(snapshot: snapshot, height: 280),
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
                _navItem('行情', Icons.candlestick_chart_outlined, () {
                  if (scrollController.hasClients) scrollController.jumpTo(0);
                }, selected: true),
                _navItem(
                  '自选',
                  Icons.star_border_rounded,
                  () => assets(favoritesOnly: true),
                ),
                _navItem('RWKV', Icons.graphic_eq, minutes),
                const Spacer(),
                IconButton(
                  tooltip: '刷新行情',
                  onPressed: model.loading ? null : model.load,
                  icon: Icon(Icons.refresh, color: colors.secondary, size: 21),
                ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  onPressed: minutes,
                  icon: const Icon(Icons.auto_graph, size: 16),
                  label: const Text('分钟预测', style: TextStyle(fontSize: 13)),
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
