import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'minute_market_page.dart';

import 'api_export_page.dart';
import 'market_controller.dart';
import 'models.dart';
import 'theme.dart';

void showMarketSheet(BuildContext context, Widget child) {
  final size = MediaQuery.sizeOf(context);
  if (size.width >= 700) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 620,
          height: math.min(size.height - 64, 800),
          child: child,
        ),
      ),
    );
  } else {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height:
              MediaQuery.sizeOf(context).height * .88 -
              MediaQuery.viewInsetsOf(context).bottom,
          child: child,
        ),
      ),
    );
  }
}

class SheetFrame extends StatelessWidget {
  const SheetFrame({
    super.key,
    required this.title,
    required this.child,
    this.scroll = true,
  });
  final String title;
  final Widget child;
  final bool scroll;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 12, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: scroll
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: child,
              )
            : child,
      ),
    ],
  );
}

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key, required this.controller});
  final MarketController controller;
  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late final address = TextEditingController(text: widget.controller.baseUrl);
  late bool demo = widget.controller.demo;
  bool saving = false;
  String? error;
  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.controller.configure(useDemo: demo);
      if (!mounted) return;
      if (widget.controller.error != null) {
        setState(() => error = widget.controller.error);
      } else {
        Navigator.pop(context);
      }
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final colors = MarketColors.of(context);
      return SheetFrame(
        title: '设置',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('外观', style: TextStyle(fontSize: 12, color: colors.secondary)),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('暗色模式', style: TextStyle(fontSize: 15)),
              secondary: Icon(Icons.dark_mode_outlined, color: colors.orange),
              value: widget.controller.dark,
              onChanged: widget.controller.setDark,
            ),
            Text(
              '默认暗色，自动保存你的选择。',
              style: TextStyle(fontSize: 11, color: colors.secondary),
            ),
            const SizedBox(height: 28),
            ListTile(
              key: const ValueKey('rwkv-model-entry'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.memory, color: colors.orange),
              title: const Text('RWKV 分钟预测', style: TextStyle(fontSize: 15)),
              subtitle: const Text(
                '查看分钟行情、安装模型并预测未来 30 分钟',
                style: TextStyle(fontSize: 11),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MinuteMarketPage(
                    controller: widget.controller,
                    instrument:
                        widget.controller.snapshot?.asset ??
                        widget.controller.assets.first,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              key: const ValueKey('api-export-entry'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.folder_zip_outlined, color: colors.orange),
              title: const Text('接口数据导出与分享', style: TextStyle(fontSize: 15)),
              subtitle: const Text(
                '每次请求一个 JSON，支持单独分享或打包导出',
                style: TextStyle(fontSize: 11),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      ApiExportPage(log: widget.controller.requestLog),
                ),
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              '行情服务地址',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: address,
              key: const ValueKey('service-address'),
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'API 地址',
                suffixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '行情统一连接此服务器。',
              style: TextStyle(
                fontSize: 12,
                color: colors.secondary,
                height: 1.8,
              ),
            ),
            const SizedBox(height: 20),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('离线演示', style: TextStyle(fontSize: 15)),
              value: demo,
              subtitle: const Text(
                '仅展示样例日线行情，本次会话生效；分钟预测需要真实行情。',
                style: TextStyle(fontSize: 11),
              ),
              onChanged: saving
                  ? null
                  : (value) => setState(() => demo = value),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                style: TextStyle(fontSize: 12, height: 1.7, color: colors.red),
              ),
            ],
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: saving ? null : save,
                icon: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link, size: 18),
                label: Text(saving ? '正在连接…' : '保存并连接'),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class AssetPicker extends StatefulWidget {
  const AssetPicker({
    super.key,
    required this.controller,
    this.favoritesOnly = false,
  });
  final MarketController controller;
  final bool favoritesOnly;
  @override
  State<AssetPicker> createState() => _AssetPickerState();
}

class _AssetPickerState extends State<AssetPicker> {
  String query = '';
  String category = '全部';
  List<MarketInstrument> results = [];
  List<String> warnings = [];
  bool searching = false;
  bool hasMore = false;
  int total = 0;
  String? error;
  Timer? debounce;
  int generation = 0;
  final ScrollController scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    scrollController.addListener(loadMoreIfNeeded);
    if (!widget.favoritesOnly) {
      searching = true;
      fetch(++generation);
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    scrollController.dispose();
    ++generation;
    super.dispose();
  }

  void loadMoreIfNeeded() {
    if (scrollController.hasClients &&
        scrollController.position.extentAfter <= 80 &&
        error == null) {
      loadMore();
    }
  }

  void loadMore() {
    if (widget.favoritesOnly || searching || !hasMore) return;
    setState(() {
      searching = true;
      error = null;
    });
    fetch(generation, more: true);
  }

  void search({bool immediate = false}) {
    debounce?.cancel();
    final revision = ++generation;
    setState(() {
      results = [];
      warnings = [];
      error = null;
      hasMore = false;
      total = 0;
      searching = !widget.favoritesOnly;
    });
    if (widget.favoritesOnly) return;
    if (immediate) {
      fetch(revision);
    } else {
      debounce = Timer(
        const Duration(milliseconds: 350),
        () => fetch(revision),
      );
    }
  }

  Future<void> fetch(int revision, {bool more = false}) async {
    try {
      final response = await widget.controller.search(
        query,
        kind: category == '全部' ? null : category,
        offset: more ? results.length : 0,
      );
      if (!mounted || revision != generation) return;
      setState(() {
        results = more ? [...results, ...response.items] : response.items;
        warnings = response.warnings;
        hasMore = response.hasMore;
        total = response.total;
        searching = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && revision == generation) loadMoreIfNeeded();
      });
    } catch (exception) {
      if (!mounted || revision != generation) return;
      setState(() {
        error = exception.toString();
        searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final colors = MarketColors.of(context);
      final model = widget.controller;
      final filtered = (widget.favoritesOnly ? model.assets : results)
          .where(
            (asset) =>
                (!widget.favoritesOnly || model.favorites.contains(asset.id)) &&
                (category == '全部' || category == asset.kind) &&
                (query.isEmpty ||
                    asset.name.toLowerCase().contains(query.toLowerCase()) ||
                    asset.symbol.contains(query)),
          )
          .toList();
      return SheetFrame(
        title: widget.favoritesOnly ? '我的自选' : '选择预测标的',
        scroll: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: TextField(
                onChanged: (value) {
                  query = value.trim();
                  search();
                },
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索 ETF、指数、股票名称或代码',
                ),
              ),
            ),
            Row(
              children: ['全部', 'ETF', '指数', '股票'].map((value) {
                final selected = category == value;
                return Expanded(
                  child: InkWell(
                    onTap: () {
                      category = value;
                      search(immediate: true);
                    },
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: selected ? colors.orange : colors.line,
                            width: selected ? 2 : .6,
                          ),
                        ),
                      ),
                      child: Text(
                        value,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: selected ? colors.orange : colors.secondary,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              color: colors.canvas,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.favoritesOnly ? '自选名称 / 代码' : '名称 / 代码',
                      style: TextStyle(fontSize: 11, color: colors.secondary),
                    ),
                  ),
                  Text(
                    '自选',
                    style: TextStyle(fontSize: 11, color: colors.secondary),
                  ),
                ],
              ),
            ),
            if (warnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                child: Text(
                  warnings.join('\n'),
                  style: TextStyle(fontSize: 11, color: colors.secondary),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    Text(
                      error!,
                      style: TextStyle(fontSize: 12, color: colors.red),
                    ),
                    TextButton(
                      onPressed: results.isEmpty
                          ? () => search(immediate: true)
                          : loadMore,
                      child: Text(results.isEmpty ? '重试搜索' : '重试加载'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: searching && filtered.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : error != null && filtered.isEmpty
                  ? const SizedBox.shrink()
                  : filtered.isEmpty
                  ? Center(
                      child: Text(
                        widget.favoritesOnly ? '暂无自选，点击行情星标即可添加。' : '没有找到相关标的',
                        style: TextStyle(color: colors.secondary),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      itemCount: filtered.length + (hasMore ? 1 : 0),
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 20, endIndent: 20),
                      itemBuilder: (context, index) {
                        if (index == filtered.length) {
                          return TextButton(
                            onPressed: searching ? null : loadMore,
                            child: Text(
                              searching ? '正在加载…' : '加载更多（共 $total 个）',
                            ),
                          );
                        }
                        final asset = filtered[index];
                        return ListTile(
                          key: ValueKey('asset-${asset.id}'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 3,
                          ),
                          selected: model.snapshot?.asset.id == asset.id,
                          selectedTileColor: colors.orangeSoft,
                          onTap: () {
                            Navigator.pop(context);
                            model.load(selectedSymbol: asset.id);
                          },
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  asset.name,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 7),
                              MarketBadge(asset.kind),
                            ],
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 7),
                            child: Text(
                              '${asset.symbol} · ${asset.subtitle}',
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.secondary,
                              ),
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: model.favorites.contains(asset.id)
                                ? '移出自选'
                                : '加入自选',
                            onPressed: () => model.toggleFavorite(
                              asset.id,
                              instrument: asset,
                            ),
                            icon: Icon(
                              model.favorites.contains(asset.id)
                                  ? Icons.star_rounded
                                  : Icons.star_outline_rounded,
                              color: model.favorites.contains(asset.id)
                                  ? colors.orange
                                  : colors.secondary,
                              size: 22,
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                widget.favoritesOnly
                    ? '选择标的查看历史行情'
                    : 'AKShare · A 股、场内 ETF 与指数 · 点击查看历史行情',
                style: TextStyle(fontSize: 10, color: colors.secondary),
              ),
            ),
          ],
        ),
      );
    },
  );
}
