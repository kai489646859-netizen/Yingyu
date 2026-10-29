import 'dart:async';
import 'package:flutter/material.dart';
import '../core/emby.dart';
import '../core/home_order.dart';
import '../core/models.dart';
import '../core/version_groups.dart';
import 'home_visibility.dart';

/// Local saved lists have no natural server response. Validate their identities
/// only when opened, without scanning libraries or deleting personal records.
class ServerVisibilityGate extends StatefulWidget {
  const ServerVisibilityGate({
    super.key,
    required this.api,
    required this.account,
    required this.source,
    required this.items,
    required this.child,
  });
  final EmbyClient api;
  final Session account;
  final Listenable source;
  final List<MediaItem> Function() items;
  final Widget child;
  @override
  State<ServerVisibilityGate> createState() => _ServerVisibilityGateState();
}

class _ServerVisibilityGateState extends State<ServerVisibilityGate> {
  HomeOrder? policy;
  int revision = -1;
  Session? resolutionAccount;
  final attempted = <String>{};
  bool scheduled = false, loading = false;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.source.addListener(schedule);
    widget.api.backgroundWork.addListener(schedule);
  }

  @override
  void didUpdateWidget(ServerVisibilityGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      oldWidget.source.removeListener(schedule);
      widget.source.addListener(schedule);
    }
    if (oldWidget.api != widget.api) {
      oldWidget.api.backgroundWork.removeListener(schedule);
      widget.api.backgroundWork.addListener(schedule);
    }
    schedule();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    policy = HomeVisibilityScope.of(context);
    schedule();
  }

  @override
  void dispose() {
    widget.source.removeListener(schedule);
    widget.api.backgroundWork.removeListener(schedule);
    super.dispose();
  }

  void schedule() {
    if (scheduled || loading) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (mounted) unawaited(confirm());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> confirm() async {
    final order = policy, api = widget.api, account = widget.account;
    if (order == null ||
        !order.serverHandlesHidden(account) ||
        !identical(api.session, account) ||
        api.backgroundWork.paused) {
      return;
    }
    final ticket = order.serverRevision(account);
    if (revision != ticket || !identical(resolutionAccount, account)) {
      revision = ticket;
      resolutionAccount = account;
      attempted.clear();
    }
    final candidates = [
      for (final item in widget.items())
        if (item is VersionGroup) ...item.versions else item,
    ];
    final wanted = candidates
        .where(
          (item) =>
              item.id.isNotEmpty &&
              !attempted.contains(item.id) &&
              order.needsServerConfirmation(account, [item]),
        )
        .map((item) => item.id)
        .toSet();
    if (wanted.isEmpty) return;
    attempted.addAll(wanted);
    setState(() {
      loading = true;
      error = null;
    });
    bool current() =>
        mounted &&
        identical(api.session, account) &&
        order.serverRevision(account) == ticket &&
        order.serverHandlesHidden(account) &&
        !api.backgroundWork.paused;
    try {
      for (final batch in itemLookupBatches(wanted)) {
        if (!current()) return;
        final values = await api.backgroundWork.run(
          () => api.progressItems(batch),
        );
        if (!current()) return;
        final expected = batch.toSet();
        order.observeServerItems(
          account,
          values.where((item) => expected.contains(item.id)),
          revision: ticket,
        );
      }
    } catch (e) {
      if (current()) error = safeError(e);
    } finally {
      if (!current()) attempted.removeAll(wanted);
      if (mounted) {
        setState(() => loading = false);
        schedule();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (loading)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('正在确认本机保存影片的访问范围'),
        ),
      if (error != null)
        TextButton(
          onPressed: () {
            attempted.clear();
            unawaited(confirm());
          },
          child: Text('访问范围确认失败，点击重试：$error'),
        ),
      Expanded(child: widget.child),
    ],
  );
}
