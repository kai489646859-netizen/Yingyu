import 'package:flutter/widgets.dart';

/// Reflects the lifetime of an existing selector without changing its navigation.
class ExpansionAction extends StatefulWidget {
  const ExpansionAction({
    super.key,
    required this.onOpen,
    required this.builder,
  });
  final Future<void> Function()? onOpen;
  final Widget Function(bool expanded, VoidCallback? activate) builder;
  @override
  State<ExpansionAction> createState() => _ExpansionActionState();
}

class _ExpansionActionState extends State<ExpansionAction> {
  bool expanded = false;
  Future<void> openMenu() async {
    final action = widget.onOpen;
    if (action == null || expanded) return;
    setState(() => expanded = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => expanded = false);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    expanded,
    widget.onOpen == null || expanded ? null : openMenu,
  );
}
