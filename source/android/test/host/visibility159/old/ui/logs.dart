import 'package:flutter/cupertino.dart';
import 'style.dart';
import 'surface.dart';
import 'scroll_to_top.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/log.dart';
import '../core/log_export.dart';
import '../version.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.log});
  final DiagnosticLog log;
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String? copyNotice;
  bool errorsOnly = false;
  bool selecting = false;
  bool exporting = false;
  bool confirmingClear = false;
  final selected = <LogEntry>{};
  Future<void> confirmClear() async {
    if (confirmingClear) return;
    confirmingClear = true;
    try {
      final clear = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('清空日志？'),
          content: const Text('现有日志将被删除，请先导出需要保留的记录。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认清空'),
            ),
          ],
        ),
      );
      if (!mounted || clear != true) return;
      await widget.log.clear();
      if (mounted) {
        setState(() {
          selected.clear();
          visibleRows = null;
          copyNotice = null;
        });
      }
    } finally {
      confirmingClear = false;
    }
  }

  final scroll = ScrollController();
  List<LogEntry>? visibleRows;
  LogEntry? newest;
  final extents = _LogRowExtents();
  bool refreshQueued = false;
  @override
  void initState() {
    super.initState();
    scroll.addListener(refreshAtTop);
  }

  void refreshAtTop() {
    if (!scroll.hasClients ||
        scroll.offset > 0 ||
        refreshQueued ||
        newest == widget.log.entries.lastOrNull) {
      return;
    }
    refreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      refreshQueued = false;
      if (mounted && scroll.hasClients && scroll.offset <= 0) {
        setState(() => visibleRows = null);
      }
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void toggle(LogEntry entry) => setState(() {
    selecting = true;
    if (!selected.add(entry)) selected.remove(entry);
  });

  Future<void> copy({bool selectedOnly = false}) async {
    final snapshot = LogExportSnapshot(
      widget.log,
      selection: selectedOnly ? Set.of(selected) : null,
    );
    final parts = snapshot.parts;
    if (parts.length > 1) {
      final save = await showCupertinoDialog<bool>(
        context: context,
        builder: (_) => _CopyLogParts(parts: parts),
      );
      if (save == true && mounted) await saveFile(snapshot);
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: parts.single));
      if (mounted) {
        setState(
          () => copyNotice = selectedOnly ? '所选日志已复制，最新记录在前' : '最近日志已复制，最新记录在前',
        );
      }
    } catch (_) {
      if (mounted) setState(() => copyNotice = '复制失败，请使用“导出日志文件”');
    }
  }

  Future<void> saveFile(LogExportSnapshot snapshot) async {
    if (exporting) return;
    setState(() => exporting = true);
    try {
      final saved = await LogFileExport.save(snapshot);
      if (mounted) {
        setState(
          () => copyNotice = saved
              ? '已保存 ${snapshot.lines.length} 条日志，可以直接发送这个 TXT 文件'
              : '已取消保存，日志仍保留在本机',
        );
      }
    } catch (_) {
      if (mounted) setState(() => copyNotice = '文件未能完整保存，请重试或使用分段复制');
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.log,
    builder: (context, _) {
      final entries = widget.log.entries;
      selected.retainAll(entries);
      // Keep the visible history stable while reading older entries. New
      // records still persist/export immediately; reveal them back at the top.
      if (visibleRows == null ||
          entries.isEmpty ||
          !scroll.hasClients ||
          (scroll.offset <= 0 && newest != entries.lastOrNull)) {
        newest = entries.lastOrNull;
        visibleRows = entries.reversed
            .where((e) => !errorsOnly || e.level != LogLevel.info)
            .take(logVisibleEntries)
            .toList();
      }
      final rows = visibleRows!;
      return SurfacePage(
        title: '日志记录',
        child: ScrollToTop(
          controller: scroll,
          referenceStyle: true,
          posterAware: false,
          child: CustomScrollView(
            controller: scroll,
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    if (copyNotice != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Text(
                          copyNotice!,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    SettingsGroup(
                      children: [
                        SettingsRow(
                          '记录诊断日志',
                          subtitle:
                              '本机保留 ${entries.length} 条 · ${(widget.log.storedBytes / (1024 * 1024)).toStringAsFixed(1)} / 8 MiB\n页面最多显示最近 500 条，导出全部保留记录\n构建 $diagnosticBuild',
                          trailing: CupertinoSwitch(
                            value: widget.log.enabled,
                            onChanged: widget.log.setEnabled,
                          ),
                        ),
                        SettingsRow(
                          '仅警告与错误',
                          trailing: CupertinoSwitch(
                            value: errorsOnly,
                            onChanged: (value) {
                              if (scroll.hasClients) scroll.jumpTo(0);
                              setState(() {
                                errorsOnly = value;
                                visibleRows = null;
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 0,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          CupertinoButton(
                            key: const Key('export-log-file'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            onPressed: entries.isEmpty || exporting
                                ? null
                                : () => saveFile(LogExportSnapshot(widget.log)),
                            child: Text(
                              exporting ? '正在导出…' : '导出日志文件',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          CupertinoButton(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            onPressed: entries.isEmpty ? null : () => copy(),
                            child: const Text(
                              '复制最新日志',
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                          CupertinoButton(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            onPressed: () => setState(() {
                              selecting = !selecting;
                              selected.clear();
                            }),
                            child: Text(
                              selecting ? '取消选择' : '选择日志',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          CupertinoButton(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            onPressed: entries.isEmpty ? null : confirmClear,
                            child: Text(
                              '清空',
                              style: TextStyle(
                                fontSize: 14,
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                          if (selecting) ...[
                            CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 8,
                              ),
                              onPressed: selected.isEmpty || exporting
                                  ? null
                                  : () => saveFile(
                                      LogExportSnapshot(
                                        widget.log,
                                        selection: Set.of(selected),
                                      ),
                                    ),
                              child: const Text(
                                '导出所选文件',
                                style: TextStyle(fontSize: 14),
                              ),
                            ),
                            CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 8,
                              ),
                              onPressed: rows.isEmpty
                                  ? null
                                  : () => setState(() => selected.addAll(rows)),
                              child: const Text(
                                '全选当前列表',
                                style: TextStyle(fontSize: 14),
                              ),
                            ),
                            CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 8,
                              ),
                              onPressed: selected.isEmpty
                                  ? null
                                  : () => copy(selectedOnly: true),
                              child: Text(
                                '复制所选（${selected.length}）',
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (widget.log.storageError != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          widget.log.storageError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const Divider(height: 1),
                  ],
                ),
              ),
              if (rows.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: MessagePanel('暂无日志', icon: CupertinoIcons.doc_text),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 88),
                  sliver: SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final heights = extents.measure(
                        context,
                        rows,
                        constraints.crossAxisExtent - (selecting ? 34 : 0),
                      );
                      return SliverVariedExtentList(
                        itemExtentBuilder: (index, _) =>
                            index >= rows.length * 2 - 1
                            ? null
                            : index.isOdd
                            ? 24
                            : heights[index ~/ 2],
                        delegate: _LogRowsDelegate(heights, (context, index) {
                          if (index.isOdd) return const Divider(height: 24);
                          index ~/= 2;
                          final row = rows[index];
                          return GestureDetector(
                            key: ValueKey(row),
                            behavior: HitTestBehavior.opaque,
                            onLongPress: () => toggle(row),
                            onTap: selecting ? () => toggle(row) : null,
                            child: ColoredBox(
                              color: selected.contains(row)
                                  ? accentColor(context).withValues(alpha: .08)
                                  : Colors.transparent,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (selecting)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 12),
                                      child: Icon(
                                        selected.contains(row)
                                            ? CupertinoIcons
                                                  .check_mark_circled_solid
                                            : CupertinoIcons.circle,
                                        color: selected.contains(row)
                                            ? accentColor(context)
                                            : secondaryColor(context),
                                        size: 22,
                                      ),
                                    ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _logHeading(row),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: row.level == LogLevel.error
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.error
                                                : secondaryColor(context),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        if (selecting)
                                          Text(
                                            row.message,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              height: 1.5,
                                            ),
                                          )
                                        else
                                          SelectableText(
                                            row.message,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              height: 1.5,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

String _logHeading(LogEntry row) =>
    '${row.time.toLocal().toIso8601String().replaceFirst('T', ' ')}  ·  ${row.level.label}  ·  ${row.area.label}';

/// A lazy variable-height SliverList continually estimates its total extent
/// from the currently visible rows. Diagnostic messages differ by hundreds of
/// pixels, which makes its scrollbar jump. Measure the bounded snapshot once
/// and give the lazy viewport exact row extents, including large text/rotation.
class _LogRowExtents {
  List<LogEntry>? _rows;
  double? _width;
  TextScaler? _scale;
  TextStyle? _style;
  TextDirection? _direction;
  List<double> _heights = [];
  List<double> measure(
    BuildContext context,
    List<LogEntry> rows,
    double width,
  ) {
    final style = DefaultTextStyle.of(context).style;
    final scale = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    if (identical(rows, _rows) &&
        width == _width &&
        scale == _scale &&
        style == _style &&
        direction == _direction) {
      return _heights;
    }
    _rows = rows;
    _width = width;
    _scale = scale;
    _style = style;
    _direction = direction;
    double height(String text, TextStyle format, {double caretMargin = 0}) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style.merge(format)),
        textScaler: scale,
        textDirection: direction,
      )..layout(maxWidth: (width - caretMargin).clamp(1, double.infinity));
      final result = painter.height;
      painter.dispose();
      return result;
    }

    return _heights = [
      for (final row in rows)
        (height(_logHeading(row), const TextStyle(fontSize: 12)) +
                6 +
                height(
                  row.message,
                  const TextStyle(fontSize: 13, height: 1.5),
                  // SelectableText reserves a 2px cursor plus a 1px caret gap.
                  caretMargin: 3,
                ) +
                2)
            .ceilToDouble(),
    ];
  }
}

class _LogRowsDelegate extends SliverChildBuilderDelegate {
  _LogRowsDelegate(List<double> heights, super.builder)
    : extent =
          heights.fold<double>(0, (sum, h) => sum + h) +
          (heights.length - 1) * 24,
      super(childCount: heights.length * 2 - 1);
  final double extent;
  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => extent;
}

class _CopyLogParts extends StatefulWidget {
  const _CopyLogParts({required this.parts});
  final List<String> parts;
  @override
  State<_CopyLogParts> createState() => _CopyLogPartsState();
}

class _CopyLogPartsState extends State<_CopyLogParts> {
  int index = 0;
  String? notice;
  bool copying = false;
  Future<void> copy() async {
    if (copying) return;
    setState(() => copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: widget.parts[index]));
      if (mounted) setState(() => notice = '第 ${index + 1} 段已复制，请先粘贴再复制下一段');
    } catch (_) {
      if (mounted) setState(() => notice = '复制失败，可以保存完整文件后发送');
    } finally {
      if (mounted) setState(() => copying = false);
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoAlertDialog(
    title: const Text('日志较多，分段复制'),
    content: Text(
      '第 ${index + 1} / ${widget.parts.length} 段\n'
      '${notice ?? '保存文件可一次导出全部日志；分段复制不会丢失记录。'}',
    ),
    actions: [
      CupertinoDialogAction(
        onPressed: copying ? null : copy,
        child: Text('复制第 ${index + 1} 段'),
      ),
      if (index + 1 < widget.parts.length)
        CupertinoDialogAction(
          onPressed: copying
              ? null
              : () => setState(() {
                  index++;
                  notice = null;
                }),
          child: const Text('下一段'),
        ),
      if (index > 0)
        CupertinoDialogAction(
          onPressed: copying
              ? null
              : () => setState(() {
                  index--;
                  notice = null;
                }),
          child: const Text('上一段'),
        ),
      CupertinoDialogAction(
        onPressed: copying ? null : () => Navigator.pop(context, true),
        child: const Text('保存完整文件'),
      ),
      CupertinoDialogAction(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('完成'),
      ),
    ],
  );
}
