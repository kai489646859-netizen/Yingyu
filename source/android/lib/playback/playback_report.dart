import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/log.dart';
import '../core/log_export.dart';
import '../ui/surface.dart';
import '../version.dart';

class PlaybackReport {
  PlaybackReport({
    required this.log,
    required DateTime started,
    required this.title,
    required this.position,
    DateTime? created,
  }) : time = created ?? DateTime.now() {
    final cutoff = time.subtract(const Duration(minutes: 10));
    final rows = <String>[];
    var bytes = 0;
    for (final row in log.entries.reversed) {
      if (row.time.isBefore(cutoff) ||
          row.time.isBefore(started) ||
          row.time.isAfter(time) ||
          row.version != appVersion ||
          row.buildCode != androidVersionCode ||
          !const {
            LogArea.player,
            LogArea.network,
            LogArea.route,
          }.contains(row.area)) {
        continue;
      }
      final line = log.sanitize(row.line);
      bytes += utf8.encode(line).length + 1;
      if (bytes > 12 * 1024 || rows.length == 150) break;
      rows.add(line);
    }
    diagnostics = List.unmodifiable(rows);
  }
  final DiagnosticLog log;
  final String title;
  final Duration position;
  final DateTime time;
  late final List<String> diagnostics;
  static const categories = ['播放异常', '字幕问题', '音频问题', '弹幕问题', '其他'];

  String render({
    required String category,
    required String description,
    required bool includeTitle,
    required bool includeDiagnostics,
  }) {
    return [
      '映屿安卓播放问题反馈 · $appVersion/code$androidVersionCode',
      '记录时间：${time.toIso8601String()}',
      '问题类型：$category',
      '播放位置：${position.inMilliseconds / 1000} 秒',
      if (includeTitle) '影片：${log.sanitize(title)}',
      '说明：${log.sanitize(description.trim())}',
      if (includeDiagnostics) ...[
        '本次播放近 10 分钟的脱敏诊断（${diagnostics.length} 条，最新在前）：',
        ...diagnostics,
      ],
    ].join('\n');
  }
}

class PlaybackReportPage extends StatefulWidget {
  const PlaybackReportPage({super.key, required this.report});
  final PlaybackReport report;
  @override
  State<PlaybackReportPage> createState() => _PlaybackReportPageState();
}

class _PlaybackReportPageState extends State<PlaybackReportPage> {
  final description = TextEditingController();
  String category = PlaybackReport.categories.first;
  String? preview, status;
  bool withTitle = false, withDiagnostics = false, saving = false;

  @override
  void dispose() {
    description.dispose();
    super.dispose();
  }

  Future<void> _export({bool copy = false}) async {
    final text = preview;
    if (text == null || saving) return;
    setState(() => saving = true);
    try {
      if (copy) {
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) setState(() => status = '已复制反馈，可发送给维护者');
      } else {
        final exported = await LogFileExport.saveText(
          text,
          '映屿播放反馈-${widget.report.time.millisecondsSinceEpoch}.txt',
        );
        if (mounted) setState(() => status = exported ? '反馈文件已保存' : '已取消导出');
      }
    } catch (_) {
      if (mounted) setState(() => status = '暂时无法${copy ? '复制' : '导出'}反馈');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SurfacePage(
    title: '播放问题反馈',
    heightRatio: .88,
    child: Material(
      type: MaterialType.transparency,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          if (preview == null) ...[
            DropdownButtonFormField<String>(
              initialValue: category,
              decoration: const InputDecoration(labelText: '问题类型'),
              items: [
                for (final option in PlaybackReport.categories)
                  DropdownMenuItem(value: option, child: Text(option)),
              ],
              onChanged: (v) => setState(() => category = v ?? category),
            ),
            TextField(
              controller: description,
              minLines: 2,
              maxLines: 5,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: '描述发生了什么'),
              onChanged: (_) => setState(() {}),
            ),
            SwitchListTile(
              title: const Text('附上影片名称'),
              value: withTitle,
              onChanged: (v) => setState(() => withTitle = v),
            ),
            SwitchListTile(
              title: const Text('附上本次播放的脱敏日志'),
              subtitle: Text(
                '最近 10 分钟内收集到 ${widget.report.diagnostics.length} 条',
              ),
              value: withDiagnostics,
              onChanged: (v) => setState(() => withDiagnostics = v),
            ),
            FilledButton(
              onPressed: description.text.trim().runes.length < 3
                  ? null
                  : () => setState(
                      () => preview = widget.report.render(
                        category: category,
                        description: description.text,
                        includeTitle: withTitle,
                        includeDiagnostics: withDiagnostics,
                      ),
                    ),
              child: const Text('预览反馈'),
            ),
          ] else ...[
            SelectableText(preview!),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () => setState(() {
                          preview = status = null;
                        }),
                  child: const Text('继续编辑'),
                ),
                OutlinedButton(
                  onPressed: saving ? null : () => _export(copy: true),
                  child: const Text('复制'),
                ),
                FilledButton(
                  onPressed: saving ? null : _export,
                  child: const Text('导出文件'),
                ),
              ],
            ),
          ],
          Text(status ?? '反馈在本机生成，由你选择发给谁。'),
        ],
      ),
    ),
  );
}
