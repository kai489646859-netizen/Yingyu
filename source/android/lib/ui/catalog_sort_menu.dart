import 'package:flutter/material.dart';
import '../core/catalog_sort.dart';
import 'browse_menu.dart';
import 'style.dart';

Future<String?> showCatalogSortMenu(
  BuildContext context, {
  required BrowseMenuController controller,
  required GlobalKey anchor,
  required String sort,
  required bool descending,
  bool? played,
}) => controller.show(
  anchor: anchor,
  label: '排序',
  alignRight: true,
  builder: (select) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _heading(context, '排序依据'),
      for (final entry in catalogSortLabels.entries)
        _choice(
          context,
          value: 'sort:${entry.key}',
          title: entry.value,
          selected: sort == entry.key,
          select: select,
        ),
      const Divider(height: 9),
      _heading(context, '排序方式'),
      _choice(
        context,
        value: 'order:ascending',
        title: '升序',
        selected: !descending,
        select: select,
      ),
      _choice(
        context,
        value: 'order:descending',
        title: '降序',
        selected: descending,
        select: select,
      ),
      const Divider(height: 9),
      _heading(context, '观看状态'),
      for (final entry in const {
        'all': '全部',
        'false': '未看',
        'true': '已看',
      }.entries)
        _choice(
          context,
          value: 'played:${entry.key}',
          title: entry.value,
          selected: (played?.toString() ?? 'all') == entry.key,
          select: select,
        ),
    ],
  ),
);

Widget _heading(BuildContext context, String title) => Align(
  alignment: Alignment.centerLeft,
  child: Padding(
    padding: const EdgeInsets.fromLTRB(12, 5, 12, 3),
    child: Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: secondaryColor(context)),
    ),
  ),
);

Widget _choice(
  BuildContext context, {
  required String value,
  required String title,
  required bool selected,
  required ValueChanged<String> select,
}) => BrowseMenuChoice(
  key: ValueKey(value),
  title: title,
  selected: selected,
  onTap: () => select(value),
);

/// Three horizontal strokes and a downward arrow, matching the supplied menu.
class CatalogSortIcon extends StatelessWidget {
  const CatalogSortIcon({super.key, this.active = false});
  final bool active;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 26,
    height: 26,
    child: CustomPaint(
      painter: _SortPainter(
        accentColor(context).withValues(alpha: active ? 1 : .85),
      ),
    ),
  );
}

class _SortPainter extends CustomPainter {
  const _SortPainter(this.color);
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
        ..moveTo(18, 13)
        ..lineTo(21, 16)
        ..lineTo(24, 13),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SortPainter oldDelegate) => oldDelegate.color != color;
}
