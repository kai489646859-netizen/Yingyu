import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import '../core/models.dart';

/// Preserve an actual top-row item when a responsive grid changes columns.
/// Viewport corrections happen during layout, before a wrongly positioned
/// frame can be painted. Ordinary scrolling and data/filter resets stay intact.
class AnchoredSliverGrid extends SliverGrid {
  const AnchoredSliverGrid({
    super.key,
    required super.delegate,
    required super.gridDelegate,
    required this.items,
  });
  final List<MediaItem> items;
  @override
  RenderSliverGrid createRenderObject(BuildContext context) => _AnchoredGrid(
    childManager: context as SliverMultiBoxAdaptorElement,
    gridDelegate: gridDelegate,
    items: items,
  );
  @override
  void updateRenderObject(BuildContext context, RenderSliverGrid renderObject) {
    (renderObject as _AnchoredGrid).items = items;
    super.updateRenderObject(context, renderObject);
  }
}

class _AnchoredGrid extends RenderSliverGrid {
  _AnchoredGrid({
    required super.childManager,
    required super.gridDelegate,
    required this.items,
  });
  List<MediaItem> items;
  int? columns;
  double? stride, lastOffset;
  String? anchorId;
  String? lastLeadingId;
  int lastCount = 0;
  double fraction = 0;
  bool correcting = false;

  @override
  void performLayout() {
    final layout =
        gridDelegate.getLayout(constraints) as SliverGridRegularTileLayout;
    final offset = constraints.scrollOffset;
    final changed =
        columns != null &&
        (columns != layout.crossAxisCount || stride != layout.mainAxisStride);
    if (changed && anchorId != null && items.isNotEmpty) {
      final at = items.indexWhere((item) => item.id == anchorId);
      columns = layout.crossAxisCount;
      stride = layout.mainAxisStride;
      if (at >= 0 && offset > 0) {
        final target = (at ~/ columns! + fraction) * stride!;
        if ((target - offset).abs() > .01) {
          correcting = true;
          geometry = SliverGeometry(scrollOffsetCorrection: target - offset);
          return;
        }
      }
    }
    columns = layout.crossAxisCount;
    stride = layout.mainAxisStride;
    final gap = stride! - layout.childMainAxisExtent;
    final row = ((offset + gap) / stride!).floor();
    final at = row * columns!;
    final leading = at < items.length ? items[at].id : null;
    // Keep the same identity across repeated rotations instead of rounding
    // it backwards to the first cell of each newly sized row.
    if (!correcting &&
        !changed &&
        (lastOffset == null ||
            (lastOffset! - offset).abs() > .01 ||
            lastLeadingId != leading ||
            lastCount != items.length)) {
      anchorId = leading;
      fraction = offset / stride! - row;
    }
    correcting = false;
    lastOffset = offset;
    lastLeadingId = leading;
    lastCount = items.length;
    super.performLayout();
  }
}
