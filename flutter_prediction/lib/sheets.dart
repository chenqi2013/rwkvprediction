import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

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
      await widget.controller.configure(address.text, demo);
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
            const Text(
              '行情服务地址',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: address,
              key: const ValueKey('service-address'),
              keyboardType: TextInputType.url,
              autocorrect: false,
              enabled: !saving,
              decoration: const InputDecoration(
                hintText: 'http://192.168.1.89:8787',
                labelText: 'API 地址',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '桌面和 iOS 模拟器可使用 127.0.0.1；Android 模拟器使用 10.0.2.2。真机填写电脑的局域网 IP，手机和电脑连接同一 Wi-Fi，并允许本地网络访问。',
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
                '开启后行情与预测均为模拟，本次会话生效。',
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

  @override
  void initState() {
    super.initState();
    if (!widget.favoritesOnly) {
      searching = true;
      fetch(++generation);
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    ++generation;
    super.dispose();
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
            SegmentedButton<String>(
              segments: ['全部', 'ETF', '指数', '股票']
                  .map(
                    (value) => ButtonSegment(value: value, label: Text(value)),
                  )
                  .toList(),
              selected: {category},
              showSelectedIcon: false,
              onSelectionChanged: (value) {
                category = value.first;
                search(immediate: true);
              },
            ),
            const SizedBox(height: 12),
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
                      onPressed: () => search(immediate: true),
                      child: const Text('重试搜索'),
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
                      itemCount: filtered.length + (hasMore ? 1 : 0),
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 20, endIndent: 20),
                      itemBuilder: (context, index) {
                        if (index == filtered.length) {
                          return TextButton(
                            onPressed: searching
                                ? null
                                : () {
                                    setState(() {
                                      searching = true;
                                      error = null;
                                    });
                                    fetch(++generation, more: true);
                                  },
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
                            vertical: 9,
                          ),
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
                          trailing: Icon(
                            model.symbol == asset.id
                                ? Icons.check
                                : Icons.chevron_right,
                            color: model.symbol == asset.id
                                ? colors.orange
                                : colors.secondary,
                            size: 18,
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

String predictionReport(
  MarketSnapshot snapshot,
  Forecast forecast,
  int confidence,
) {
  final asset = snapshot.asset;
  return '【知势 · RWKV 模拟预测】\n${asset.name} ${asset.symbol}\n'
      '收盘价格：${asset.format(asset.price)} CNY\n行情截至：${snapshot.asOf}\n'
      '未来 ${forecast.horizon} 个交易日\n$confidence% 期末区间：'
      '${asset.format(forecast.last.lower(confidence))} – ${asset.format(forecast.last.upper(confidence))}\n'
      '中位预期：${asset.format(forecast.last.median)}\n\n${forecast.explanation}\n\n'
      '${snapshot.description}\n不构成投资建议。';
}

class DeliverySheet extends StatefulWidget {
  const DeliverySheet({super.key, required this.controller});
  final MarketController controller;
  @override
  State<DeliverySheet> createState() => _DeliverySheetState();
}

class _DeliverySheetState extends State<DeliverySheet> {
  String channel = 'in_app';
  bool sending = false;
  bool sent = false;
  String? error;
  late final report = predictionReport(
    widget.controller.snapshot!,
    widget.controller.forecast!,
    widget.controller.confidence,
  );
  Future<void> send() async {
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.controller.deliver(channel);
      if (mounted) setState(() => sent = true);
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    return SheetFrame(
      title: '下发预测',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sent)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.check_circle, color: colors.green, size: 58),
                    const SizedBox(height: 18),
                    const Text(
                      '预测已下发',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      channel == 'in_app'
                          ? '已保存到站内消息，可在下发记录中查看。'
                          : '已保存演示 Webhook 记录，未向外部系统发出请求。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.secondary, height: 1.7),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: colors.orangeSoft,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(Icons.send_rounded, color: colors.orange),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '把洞察，送到下一步',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text('包含走势区间、市场解读与数据来源', style: TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Container(
              padding: const EdgeInsets.all(18),
              width: double.infinity,
              decoration: BoxDecoration(
                color: colors.canvas,
                borderRadius: BorderRadius.circular(14),
              ),
              child: SelectableText(
                report,
                style: TextStyle(fontSize: 12, color: colors.body, height: 1.8),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '下发渠道',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            ...[
              ('in_app', '站内消息', '生成记录，保存到当前设备', Icons.inbox_outlined),
              ('webhook_demo', 'Webhook · 演示', '展示系统集成流程，不发送外部请求', Icons.link),
            ].map(
              (option) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: sending
                      ? null
                      : () => setState(() => channel = option.$1),
                  child: Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: channel == option.$1
                          ? colors.orangeSoft
                          : colors.canvas,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Row(
                      children: [
                        Icon(option.$4, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                option.$2,
                                style: const TextStyle(fontSize: 14),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                option.$3,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.secondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          channel == option.$1
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: channel == option.$1
                              ? colors.orange
                              : colors.secondary,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  error!,
                  style: TextStyle(color: colors.red, fontSize: 12),
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: sending ? null : send,
                child: Text(sending ? '正在下发…' : '确认下发'),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Center(
            child: TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: report));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('预测摘要已复制，可粘贴分享')),
                  );
                }
              },
              icon: const Icon(Icons.copy_outlined, size: 17),
              label: const Text('复制预测摘要'),
            ),
          ),
        ],
      ),
    );
  }
}

class HistorySheet extends StatelessWidget {
  const HistorySheet({super.key, required this.controller});
  final MarketController controller;
  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    return SheetFrame(
      title: '下发记录',
      child: controller.deliveries.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 80),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.inbox_outlined,
                      size: 46,
                      color: colors.secondary,
                    ),
                    const SizedBox(height: 18),
                    const Text('暂无下发记录'),
                    const SizedBox(height: 8),
                    Text(
                      '在预测页面点击「下发预测」，保存第一份市场洞察。',
                      style: TextStyle(color: colors.secondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: controller.deliveries.map((receipt) {
                final forecast = receipt['forecast'] as Json?;
                final decimals = forecast?['decimals'] as int? ?? 3;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: MarketPanel(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                receipt['asset_name'],
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              '演示下发成功',
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.green,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          receipt['channel'] == 'in_app'
                              ? '站内消息 · 已保存'
                              : 'Webhook · 演示记录',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.secondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          receipt['created_at'],
                          style: TextStyle(
                            fontSize: 10,
                            color: colors.secondary,
                          ),
                        ),
                        if (forecast != null)
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: EdgeInsets.zero,
                            title: const Text(
                              '查看预测内容',
                              style: TextStyle(fontSize: 12),
                            ),
                            children: [
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '未来 ${forecast['horizon']} 个交易日 · ${forecast['confidence']}% 区间',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      '${number(forecast['lower']).toStringAsFixed(decimals)} – ${number(forecast['upper']).toStringAsFixed(decimals)} CNY',
                                      style: const TextStyle(
                                        fontSize: 19,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      forecast['explanation'],
                                      style: TextStyle(
                                        color: colors.body,
                                        fontSize: 12,
                                        height: 1.7,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      forecast['market_source'] == 'akshare'
                                          ? '行情：AKShare · 预测与解读：模拟'
                                          : '行情与预测均为模拟数据',
                                      style: TextStyle(
                                        color: colors.orange,
                                        fontSize: 10,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                  ],
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
    );
  }
}

class MethodSheet extends StatelessWidget {
  const MethodSheet({super.key, required this.snapshot});
  final MarketSnapshot snapshot;
  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    return SheetFrame(
      title: '关于走势预测',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '让预测呈现不确定性',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          ...[
            (
              '区间如何阅读',
              '浅色表示所选 80% 或 95% 区间，深色表示中间 50% 区间，橙色虚线为中位走势。长按拖动或用鼠标悬停可查看每天的数值。',
            ),
            (
              '为什么区间逐渐变宽',
              '预测越远，不确定性通常越高。未来每个交易日都有上下界，能展示整段走势范围。当前区间是演示设定，未做真实模型校准。',
            ),
            ('上涨概率', '期末价格高于当前价格的模拟概率，与区间覆盖水平是不同概念。'),
            ('数据与模型', '${snapshot.description}未来日期暂只跳过周末，尚未对齐交易所节假日。'),
          ].map(
            (entry) => Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.$1,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    entry.$2,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.secondary,
                      height: 1.8,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: () async {
              final opened = await launchUrl(
                Uri.parse('https://akshare.akfamily.xyz/index.html'),
                mode: LaunchMode.externalApplication,
              );
              if (!opened && context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('无法打开浏览器，请稍后重试')));
              }
            },
            icon: const Icon(Icons.open_in_new, size: 15),
            label: const Text('查看 AKShare 数据文档'),
          ),
        ],
      ),
    );
  }
}

class CostSheet extends StatefulWidget {
  const CostSheet({super.key, required this.usage});
  final Json usage;
  @override
  State<CostSheet> createState() => _CostSheetState();
}

class _CostSheetState extends State<CostSheet> {
  final input = TextEditingController(text: '1.00');
  final output = TextEditingController(text: '2.00');
  final calls = TextEditingController(text: '10000');
  double positive(String text) {
    final value = double.tryParse(text) ?? 0;
    return value.isFinite && value > 0 ? value : 0;
  }

  @override
  void dispose() {
    input.dispose();
    output.dispose();
    calls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MarketColors.of(context);
    final perCall =
        (positive(input.text) * number(widget.usage['input_tokens']) +
            positive(output.text) * number(widget.usage['output_tokens'])) /
        1000000;
    Widget row(String title, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
    return SheetFrame(
      title: '推理成本估算',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row('模型', 'RWKV · Demo'),
          row('输入 Token', '${widget.usage['input_tokens']}'),
          row('输出 Token', '${widget.usage['output_tokens']}'),
          row('模拟耗时', '${widget.usage['latency_ms']} ms'),
          const Divider(),
          const SizedBox(height: 12),
          ...[
            (input, '输入 / 百万 Token（元）'),
            (output, '输出 / 百万 Token（元）'),
            (calls, '预计每日调用次数'),
          ].map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: TextField(
                controller: entry.$1,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: entry.$2),
              ),
            ),
          ),
          row('单次推理', '¥ ${perCall.toStringAsFixed(6)}'),
          row(
            '每日预算',
            '¥ ${(perCall * positive(calls.text)).toStringAsFixed(2)}',
          ),
          row(
            '每月预算（30日）',
            '¥ ${(perCall * positive(calls.text) * 30).toStringAsFixed(2)}',
          ),
          const SizedBox(height: 16),
          Text(
            '用量、耗时与默认单价均为示例，需接入实际推理后核算。不含行情、服务器和存储费用。',
            style: TextStyle(
              fontSize: 11,
              color: colors.secondary,
              height: 1.8,
            ),
          ),
        ],
      ),
    );
  }
}
