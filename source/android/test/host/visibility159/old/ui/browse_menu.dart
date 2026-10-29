import 'menu_placement.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'style.dart';

/// Catalogue menus share the page, so an outside drag still reaches its wall.
/// The tap recognizer wins outside taps without activating a poster underneath.
class BrowseMenuController {
  _BrowseMenuHostState? _host;

  Future<String?> show({
    required GlobalKey anchor,
    required Widget Function(ValueChanged<String>) builder,
    required String label,
    double maxHeight = 480,
    bool alignRight = false,
    ValueChanged<bool>? onDirection,
  }) =>
      _host?._show(
        anchor: anchor,
        builder: builder,
        label: label,
        maxHeight: maxHeight,
        alignRight: alignRight,
        onDirection: onDirection,
      ) ??
      Future.value();
}

class BrowseMenuHost extends StatefulWidget {
  const BrowseMenuHost({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
  });
  final BrowseMenuController controller;
  final Widget child;
  final bool enabled;
  @override
  State<BrowseMenuHost> createState() => _BrowseMenuHostState();
}

class _BrowseMenuHostState extends State<BrowseMenuHost>
    with WidgetsBindingObserver {
  LocalHistoryEntry? _history;
  Completer<String?>? _result;
  Widget? _menu;
  Rect _anchor = Rect.zero;
  String _label = '';
  double _maxHeight = 480;
  bool _alignRight = false;
  double _keyboardOverlap = 0;
  GlobalKey? _sourceAnchor;
  Size _screenSize = Size.zero;
  int _geometryRevision = 0;
  ValueChanged<bool>? _onDirection;

  @override
  void initState() {
    super.initState();
    widget.controller._host = this;
    WidgetsBinding.instance.addObserver(this);
  }

  Future<String?> _show({
    required GlobalKey anchor,
    required Widget Function(ValueChanged<String>) builder,
    required String label,
    required double maxHeight,
    required bool alignRight,
    ValueChanged<bool>? onDirection,
  }) {
    if (!widget.enabled) return Future.value();
    final box = anchor.currentContext?.findRenderObject();
    final host = context.findRenderObject();
    if (box is! RenderBox || host is! RenderBox) return Future.value();
    _close();
    final result = Completer<String?>();
    _result = result;
    _sourceAnchor = anchor;
    _screenSize = MediaQuery.sizeOf(context);
    _anchor = box.localToGlobal(Offset.zero, ancestor: host) & box.size;
    _maxHeight = maxHeight;
    _alignRight = alignRight;
    _onDirection = onDirection;
    _label = label;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    _keyboardOverlap = keyboard == 0
        ? 0
        : math.max(
            0,
            host.localToGlobal(Offset(0, host.size.height)).dy -
                (MediaQuery.sizeOf(context).height - keyboard),
          );
    _history = LocalHistoryEntry(onRemove: () => _close(historyRemoved: true));
    ModalRoute.of(context)?.addLocalHistoryEntry(_history!);
    setState(() => _menu = builder((value) => _close(value: value)));
    return result.future;
  }

  void _close({
    String? value,
    bool historyRemoved = false,
    bool rebuild = true,
  }) {
    final result = _result;
    if (result == null) return;
    final history = _history;
    _history = null;
    _result = null;
    _menu = null;
    _sourceAnchor = null;
    _geometryRevision++;
    if (!historyRemoved) history?.remove();
    if (rebuild && mounted) setState(() {});
    result.complete(value);
  }

  @override
  void didUpdateWidget(BrowseMenuHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _close(rebuild: false);
    if (oldWidget.controller != widget.controller) {
      _close(rebuild: false);
      oldWidget.controller._host = null;
      widget.controller._host = this;
    }
  }

  @override
  void didChangeMetrics() {
    // IME animation emits many metric changes after a tap. Re-anchor instead
    // of immediately closing the menu the user just opened. Rotation closes it.
    final token = ++_geometryRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _menu == null || token != _geometryRevision) return;
      if (MediaQuery.sizeOf(context) != _screenSize) {
        _close();
        return;
      }
      final box = _sourceAnchor?.currentContext?.findRenderObject();
      final host = context.findRenderObject();
      if (box is! RenderBox ||
          host is! RenderBox ||
          !box.hasSize ||
          !host.hasSize) {
        _close();
        return;
      }
      setState(() {
        _anchor = box.localToGlobal(Offset.zero, ancestor: host) & box.size;
        final keyboard = MediaQuery.viewInsetsOf(context).bottom;
        _keyboardOverlap = keyboard == 0
            ? 0
            : math.max(
                0,
                host.localToGlobal(Offset(0, host.size.height)).dy -
                    (_screenSize.height - keyboard),
              );
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _close(rebuild: false);
    widget.controller._host = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      if (_menu != null) ...[
        Positioned.fill(
          child: GestureDetector(
            key: const Key('browse-menu-outside'),
            behavior: HitTestBehavior.translucent,
            excludeFromSemantics: true,
            onTap: _close,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned.fill(
          bottom: _keyboardOverlap,
          child: CustomSingleChildLayout(
            delegate: MenuPlacement(
              anchor: _anchor,
              maxHeight: _maxHeight,
              alignRight: _alignRight,
              gap: 4,
              onDirection: (up) {
                if (mounted && _result != null) _onDirection?.call(up);
              },
            ),
            child: IntrinsicWidth(
              child: Semantics(
                label: _label,
                child: Material(
                  key: const Key('browse-menu-panel'),
                  elevation: 8,
                  shadowColor: const Color(0x28000000),
                  color: Theme.of(context).colorScheme.surface,
                  surfaceTintColor: Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: _menu,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ],
  );
}

class BrowseMenuChoice extends StatelessWidget {
  const BrowseMenuChoice({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.icon,
  });
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: const Size(0, 40),
      onPressed: onTap,
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 18,
              color: selected ? accentColor(context) : secondaryColor(context),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: selected ? accentColor(context) : labelColor(context),
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
