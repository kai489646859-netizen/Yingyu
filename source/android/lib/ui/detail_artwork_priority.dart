import 'dart:async';
import 'package:flutter/widgets.dart';

/// Local detail-page ordering, without changing the shared image scheduler.
/// Disk hits remain available immediately; only new downloads wait behind the
/// visible background. Failure or a bounded fallback always releases the gate.
class DetailArtworkPriority extends StatefulWidget {
  const DetailArtworkPriority({
    super.key,
    required this.url,
    required this.child,
  });
  final String? url;
  final Widget child;
  static bool mayDownload(
    BuildContext context, {
    required bool first,
    required String? url,
  }) {
    final scope = context.dependOnInheritedWidgetOfExactType<_Scope>();
    return scope == null || scope.ready || first && url == scope.url;
  }

  static void complete(BuildContext context, String? url) =>
      context.getInheritedWidgetOfExactType<_Scope>()?.owner.complete(url);
  @override
  State<DetailArtworkPriority> createState() => _PriorityState();
}

class _PriorityState extends State<DetailArtworkPriority> {
  Timer? fallback;
  bool ready = false, scheduled = false;
  void reset() {
    fallback?.cancel();
    scheduled = false;
    ready = widget.url == null || widget.url!.isEmpty;
    if (!ready) {
      fallback = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => ready = true);
      });
    }
  }

  void complete(String? url) {
    if (ready || scheduled || url == null || url != widget.url) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.url != url) return;
      scheduled = false;
      fallback?.cancel();
      if (!ready) setState(() => ready = true);
    });
  }

  @override
  void initState() {
    super.initState();
    reset();
  }

  @override
  void didUpdateWidget(covariant DetailArtworkPriority oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) reset();
  }

  @override
  void dispose() {
    fallback?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _Scope(owner: this, ready: ready, url: widget.url, child: widget.child);
}

class _Scope extends InheritedWidget {
  const _Scope({
    required this.owner,
    required this.ready,
    required this.url,
    required super.child,
  });
  final _PriorityState owner;
  final bool ready;
  final String? url;
  @override
  bool updateShouldNotify(_Scope old) => ready != old.ready || url != old.url;
}
