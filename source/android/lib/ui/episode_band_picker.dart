import 'package:flutter/material.dart';
import '../core/episode_bands.dart';
import 'surface.dart';
import 'anchored_menu.dart';

class EpisodeBandPicker extends StatefulWidget {
  const EpisodeBandPicker({
    super.key,
    required this.count,
    required this.selected,
    this.label,
    this.embedded = false,
  });
  final int count, selected;
  final bool embedded;
  final String Function(int)? label;
  @override
  State<EpisodeBandPicker> createState() => _EpisodeBandPickerState();
}

class _EpisodeBandPickerState extends State<EpisodeBandPicker> {
  ScrollController? _scroll;
  ScrollController get scroll => _scroll ??= ScrollController(
    initialScrollOffset:
        widget.selected *
        60.0 *
        MediaQuery.textScalerOf(context).scale(16) /
        16,
  );
  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rowHeight = 60.0 * MediaQuery.textScalerOf(context).scale(16) / 16;
    final list = SizedBox(
      height: (widget.count * rowHeight).clamp(0.0, 360.0),
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemExtent: rowHeight,
        itemCount: widget.count,
        controller: scroll,
        itemBuilder: (context, i) => SelectionRow(
          widget.label?.call(i) ?? EpisodeBands.label(i),
          selected: widget.selected == i,
          onTap: () => Navigator.pop(context, i),
        ),
      ),
    );
    if (widget.embedded) return list;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Material(
            key: const Key('selection-menu-panel'),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: 230, child: list),
          ),
        ),
      ),
    );
  }
}

/// Shares the normal menu's anchor, theme, dismissal and screen-edge rules.
class EpisodeBandButton extends StatelessWidget {
  const EpisodeBandButton({
    super.key,
    required this.id,
    required this.count,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.child,
    this.onOpenChanged,
  });
  final String id;
  final int count, selected;
  final String Function(int) label;
  final ValueChanged<int> onSelected;
  final Widget? child;
  final ValueChanged<bool>? onOpenChanged;
  @override
  Widget build(BuildContext context) => AnchoredMenuButton<int>(
    id: id,
    label: '选择集数区间',
    icon: Icons.format_list_bulleted,
    iconSize: 20,
    enabled: count > 0,
    menuWidth: compactMenuWidth(
      context,
      count > 0 ? [label(0), label(selected), label(count - 1)] : const [],
      extra: 40,
      minimum: 96,
      fontSize: 16,
    ),
    maxHeight: 360,
    items: (_) => const [],
    contentBuilder: (_) => EpisodeBandPicker(
      count: count,
      selected: selected,
      label: label,
      embedded: true,
    ),
    onSelected: onSelected,
    onOpenChanged: onOpenChanged,
    child: child == null
        ? null
        : SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: child,
            ),
          ),
  );
}
