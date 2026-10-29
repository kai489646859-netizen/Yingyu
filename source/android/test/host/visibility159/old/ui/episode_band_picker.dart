import 'package:flutter/material.dart';
import '../core/episode_bands.dart';
import 'surface.dart';

class EpisodeBandPicker extends StatefulWidget {
  const EpisodeBandPicker({
    super.key,
    required this.count,
    required this.selected,
    this.label,
  });
  final int count, selected;
  final String Function(int)? label;
  @override
  State<EpisodeBandPicker> createState() => _EpisodeBandPickerState();
}

class _EpisodeBandPickerState extends State<EpisodeBandPicker> {
  late final scroll = ScrollController(
    initialScrollOffset: widget.selected * 60.0,
  );
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Material(
      key: const Key('selection-menu-panel'),
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: (widget.label?.call(widget.count - 1).length ?? 0) > 13 || widget.count > 2000 ? 230 : 144,
        height: 360,
        child: ListView.builder(
          itemExtent: 60,
          itemCount: widget.count,
          controller: scroll,
          itemBuilder: (context, i) => SelectionRow(
            widget.label?.call(i) ?? EpisodeBands.label(i),
            selected: widget.selected == i,
            onTap: () => Navigator.pop(context, i),
          ),
        ),
      ),
    ),
  );
}
