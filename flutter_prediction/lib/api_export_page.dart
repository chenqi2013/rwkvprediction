import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'api_request_log.dart';

class ApiFileActions {
  const ApiFileActions();

  bool get canSave =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  bool get canShare => !Platform.isLinux;

  Future<void> share(File file, Rect origin) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            file.path,
            mimeType: file.path.endsWith('.zip')
                ? 'application/zip'
                : 'application/json',
          ),
        ],
        subject: '知势 · 接口请求数据',
        sharePositionOrigin: origin,
      ),
    );
  }

  Future<String?> save(File file) async {
    final location = await getSaveLocation(
      suggestedName: file.uri.pathSegments.last,
    );
    if (location == null) return null;
    await XFile(file.path).saveTo(location.path);
    return location.path;
  }
}

class ApiExportPage extends StatefulWidget {
  const ApiExportPage({
    super.key,
    required this.log,
    this.actions = const ApiFileActions(),
  });
  final ApiRequestLog log;
  final ApiFileActions actions;

  @override
  State<ApiExportPage> createState() => _ApiExportPageState();
}

class _ApiExportPageState extends State<ApiExportPage> {
  bool busy = false;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    ready = widget.log.initialized;
    if (!ready) {
      widget.log.initialize().then((_) {
        if (mounted) setState(() => ready = true);
      });
    }
  }

  Rect origin(BuildContext anchor) {
    final box = anchor.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> export(
    BuildContext anchor, {
    ApiRequestRecord? record,
    required bool share,
  }) async {
    final position = origin(anchor);
    setState(() => busy = true);
    try {
      final file = record?.file ?? await widget.log.exportArchive();
      if (share) {
        await widget.actions.share(file, position);
      } else {
        final path = await widget.actions.save(file);
        if (path != null && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('已导出到 $path')));
        }
      }
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败：$exception')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('接口数据导出')),
    body: ListenableBuilder(
      listenable: widget.log,
      builder: (context, _) {
        final records = widget.log.records;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '已保存 ${records.length} 次真实请求',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '每次请求单独保存为 JSON，包含请求参数、完整响应、状态码和时间。重复请求分别保留，重启后仍可导出。',
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '从此版本开始记录；未请求的接口和离线演示不会生成记录。预测与解读仍为模拟，以原始响应标记为准。',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      Builder(
                        builder: (anchor) => FilledButton.icon(
                          key: const ValueKey('export-all-requests'),
                          onPressed: busy || records.isEmpty
                              ? null
                              : () => export(
                                  anchor,
                                  share: !widget.actions.canSave,
                                ),
                          icon: const Icon(Icons.folder_zip_outlined),
                          label: Text(
                            widget.actions.canSave ? '导出全部 ZIP' : '导出分享全部 ZIP',
                          ),
                        ),
                      ),
                      if (widget.actions.canSave && widget.actions.canShare)
                        Builder(
                          builder: (anchor) => OutlinedButton.icon(
                            onPressed: busy || records.isEmpty
                                ? null
                                : () => export(anchor, share: true),
                            icon: const Icon(Icons.ios_share),
                            label: const Text('分享全部 ZIP'),
                          ),
                        ),
                    ],
                  ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(),
                    ),
                  if (widget.log.storageError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        widget.log.storageError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: !ready
                  ? const Center(child: CircularProgressIndicator())
                  : records.isEmpty
                  ? const Center(child: Text('暂无请求记录，先返回首页加载行情或搜索标的。'))
                  : ListView.separated(
                      itemCount: records.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final record = records[index];
                        final failed =
                            record.error != null ||
                            (record.statusCode ?? 0) >= 400;
                        return ListTile(
                          key: ValueKey(record.filename),
                          leading: Icon(
                            failed ? Icons.error_outline : Icons.data_object,
                            color: failed
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                          title: Text(
                            '${record.method} ${record.uri.path}',
                            style: const TextStyle(fontSize: 14),
                          ),
                          subtitle: Text(
                            '${record.statusCode ?? '未连接'} · ${DateTime.parse(record.startedAt).toLocal()}\n${record.uri.hasQuery ? '${record.uri.query}\n' : ''}${record.uri.host}:${record.uri.port}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          isThreeLine: true,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ApiRequestDetail(record: record),
                            ),
                          ),
                          trailing: Builder(
                            builder: (anchor) => PopupMenuButton<String>(
                              enabled: !busy,
                              tooltip: '导出此请求',
                              onSelected: (value) => export(
                                anchor,
                                record: record,
                                share: value == 'share',
                              ),
                              itemBuilder: (_) => [
                                if (widget.actions.canShare)
                                  const PopupMenuItem(
                                    value: 'share',
                                    child: Text('分享 JSON'),
                                  ),
                                if (widget.actions.canSave)
                                  const PopupMenuItem(
                                    value: 'save',
                                    child: Text('保存 JSON'),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}

class ApiRequestDetail extends StatefulWidget {
  const ApiRequestDetail({super.key, required this.record});
  final ApiRequestRecord record;

  @override
  State<ApiRequestDetail> createState() => _ApiRequestDetailState();
}

class _ApiRequestDetailState extends State<ApiRequestDetail> {
  late final content = widget.record.read();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${widget.record.method} ${widget.record.uri.path}'),
    ),
    body: FutureBuilder<String>(
      future: content,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('记录读取失败：${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Text(
              snapshot.data!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        );
      },
    ),
  );
}
