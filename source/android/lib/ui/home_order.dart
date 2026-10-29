import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import '../core/home_feed.dart';
import '../core/models.dart';
import 'style.dart';
import 'surface.dart';

/// Section placement uses both directions; catalog sorting has its own icon.
class HomeSectionOrderIcon extends StatelessWidget {
  const HomeSectionOrderIcon({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 26,
    height: 26,
    child: CustomPaint(painter: _SectionOrderPainter(accentColor(context))),
  );
}

class _SectionOrderPainter extends CustomPainter {
  const _SectionOrderPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(2, 5)
        ..lineTo(14, 5)
        ..moveTo(2, 13)
        ..lineTo(14, 13)
        ..moveTo(2, 21)
        ..lineTo(23, 21)
        ..moveTo(21, 5)
        ..lineTo(21, 16)
        ..moveTo(18, 8)
        ..lineTo(21, 5)
        ..lineTo(24, 8)
        ..moveTo(18, 13)
        ..lineTo(21, 16)
        ..lineTo(24, 13),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SectionOrderPainter oldDelegate) =>
      oldDelegate.color != color;
}

class HomeOrderPage extends StatefulWidget {
  const HomeOrderPage({super.key, required this.feed});
  final HomeFeed feed;
  @override
  State<HomeOrderPage> createState() => _HomeOrderPageState();
}

class _HomeOrderPageState extends State<HomeOrderPage> {
  late List<HomeSection> sections = widget.feed.orderedSections;
  late Set<String> hidden = widget.feed.store.homeOrder.hidden(
    widget.feed.account,
  );
  String? error;
  Future<void> writes = Future.value();
  int revision = 0;
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (!widget.feed.current || oldIndex == newIndex) return;
    setState(() {
      sections.insert(newIndex, sections.removeAt(oldIndex));
      error = null;
    });
    await save();
  }

  Future<void> save() {
    final expected = ++revision;
    final ids = sections.map((s) => s.library.id).toList();
    final hiddenIds = Set<String>.of(hidden);
    for (final section in sections) {
      widget.feed.store.homeOrder.observeSection(
        widget.feed.account,
        section.library.id,
        section.items,
      );
    }
    final previewRevision = widget.feed.store.homeOrder.previewHidden(
      widget.feed.account,
      hiddenIds,
    );
    // Keep list geometry and drag handles stable while persistence completes.
    // Serialize snapshots so a slower earlier save cannot replace the latest drag.
    return writes = writes
        .then((_) async {
          await widget.feed.store.homeOrder.save(widget.feed.account, ids);
          await widget.feed.store.homeOrder.saveHidden(
            widget.feed.account,
            hiddenIds,
            previewRevision: previewRevision,
          );
          if (mounted && expected == revision && error != null) {
            setState(() => error = null);
          }
        })
        .catchError((Object e) {
          if (mounted && expected == revision) {
            setState(() => error = '${safeError(e)}，当前设置尚未全部保存');
          }
        });
  }

  @override
  Widget build(BuildContext context) => SurfacePage(
    title: '首页分区排序',
    heightRatio: .72,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            '拖动右侧把手排序。关闭开关后，该分区及影片在应用内隐藏，包括首页、媒体库、搜索、继续观看和收藏；开启后恢复显示。',
            style: TextStyle(color: secondaryColor(context)),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (error != null)
          TextButton(onPressed: save, child: const Text('重试保存')),
        Expanded(
          child: sections.isEmpty
              ? const MessagePanel('暂无可排序分区，请先在首页加载媒体库')
              : ReorderableListView.builder(
                  key: const Key('home-section-order-list'),
                  buildDefaultDragHandles: false,
                  onReorderItem: reorder,
                  itemCount: sections.length,
                  itemBuilder: (context, index) => ListTile(
                    key: ValueKey('home-order-${sections[index].library.id}'),
                    leading: Text(
                      '${index + 1}',
                      style: TextStyle(color: secondaryColor(context)),
                    ),
                    title: Text(
                      '最新${sections[index].library.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      hidden.contains(sections[index].library.id)
                          ? '应用内隐藏'
                          : '应用内显示',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CupertinoSwitch(
                          activeTrackColor: accentColor(context),
                          key: ValueKey(
                            'home-visible-${sections[index].library.id}',
                          ),
                          value: !hidden.contains(sections[index].library.id),
                          onChanged: !widget.feed.current
                              ? null
                              : (visible) {
                                  setState(() {
                                    if (visible) {
                                      hidden.remove(sections[index].library.id);
                                    } else {
                                      hidden.add(sections[index].library.id);
                                    }
                                    error = null;
                                  });
                                  save();
                                },
                        ),
                        ReorderableDragStartListener(
                          index: index,
                          enabled: widget.feed.current,
                          child: Padding(
                            key: ValueKey(
                              'home-order-handle-${sections[index].library.id}',
                            ),
                            padding: const EdgeInsets.all(12),
                            child: Icon(
                              Icons.drag_handle,
                              semanticLabel:
                                  '拖动最新${sections[index].library.title}排序',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    ),
  );
}
