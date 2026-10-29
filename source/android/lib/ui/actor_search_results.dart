import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../core/background_work.dart';
import '../core/emby.dart';
import '../core/models.dart';
import 'people.dart';
import 'style.dart';

/// A section of the ordinary search results, sharing its query and lifetime.
class ActorSearchResults extends StatefulWidget {
  const ActorSearchResults({
    super.key,
    required this.api,
    required this.query,
    required this.active,
    required this.onItem,
  });
  final EmbyClient api;
  final String query;
  final bool active;
  final Future<void> Function(MediaItem) onItem;
  @override
  State<ActorSearchResults> createState() => _ActorSearchResultsState();
}

class _ActorSearchResultsState extends State<ActorSearchResults>
    with WidgetsBindingObserver {
  Timer? timer;
  BackgroundWork? queryWork;
  final people = <Json>[];
  int generation = 0, offset = 0;
  bool busy = false, loaded = false, more = false, foreground = true;
  String? error;
  late Session? _account = widget.api.session;
  bool get allowed =>
      mounted &&
      widget.active &&
      foreground &&
      identical(_account, widget.api.session) &&
      !widget.api.backgroundWork.paused &&
      (ModalRoute.of(context)?.isCurrent ?? true);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.api.backgroundWork.addListener(workChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    schedule();
  }

  @override
  void didUpdateWidget(covariant ActorSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      oldWidget.api.backgroundWork.removeListener(workChanged);
      widget.api.backgroundWork.addListener(workChanged);
    }
    if (!identical(_account, widget.api.session) ||
        oldWidget.query.trim() != widget.query.trim() ||
        oldWidget.api != widget.api) {
      _account = widget.api.session;
      generation++;
      queryWork?.pause(this, true);
      timer?.cancel();
      people.clear();
      offset = 0;
      error = null;
      loaded = more = busy = false;
    }
    if (!widget.active) {
      generation++;
      queryWork?.pause(this, true);
      busy = false;
      timer?.cancel();
      timer = null;
    }
    schedule();
  }

  void workChanged() {
    if (!mounted) return;
    if (widget.api.backgroundWork.paused) {
      generation++;
      queryWork?.pause(this, true);
      timer?.cancel();
      timer = null;
      if (busy) setState(() => busy = false);
    } else {
      schedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      generation++;
      queryWork?.pause(this, true);
      busy = false;
      timer?.cancel();
      timer = null;
    } else {
      schedule();
    }
  }

  void schedule() {
    if (!allowed ||
        loaded ||
        busy ||
        widget.query.trim().isEmpty ||
        timer != null) {
      return;
    }
    timer = Timer(const Duration(milliseconds: 180), () {
      timer = null;
      unawaited(load());
    });
  }

  Future<void> load({bool next = false}) async {
    if (!allowed || busy || widget.query.trim().isEmpty || next && !more) {
      return;
    }
    final revision = ++generation, account = widget.api.session;
    final term = widget.query.trim();
    queryWork?.pause(this, true);
    final queryScope = queryWork = BackgroundWork();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final page = await widget.api.backgroundWork.run(
        () => queryScope.run(
          () => widget.api.searchPeople(
            term,
            start: next ? offset : 0,
            append: next,
            allowed: () =>
                allowed &&
                revision == generation &&
                widget.query.trim() == term,
            onPartial: next
                ? null
                : (page) {
                    if (!allowed ||
                        revision != generation ||
                        widget.api.session != account) {
                      return;
                    }
                    setState(() {
                      people
                        ..clear()
                        ..addAll(page.items.map((p) => p.data));
                      offset = page.items.length;
                      more = offset < page.total;
                    });
                  },
          ),
        ),
      );
      if (!mounted ||
          !allowed ||
          revision != generation ||
          widget.api.session != account ||
          widget.query.trim() != term) {
        return;
      }
      setState(() {
        if (!next) {
          people.clear();
          offset = 0;
        }
        final ids = people.map((p) => '${p['Id']}').toSet();
        people.addAll(
          page.items.where((p) => ids.add(p.id)).map((p) => p.data),
        );
        offset += page.items.length;
        more = offset < page.total;
        loaded = true;
      });
    } on BackgroundPaused {
      // Resume only the latest query after optional browsing work is allowed.
    } catch (failure) {
      if (mounted && revision == generation && widget.api.session == account) {
        setState(() {
          error = safeError(failure);
          loaded = true;
        });
      }
    } finally {
      if (mounted && revision == generation) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    generation++;
    queryWork?.pause(this, true);
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.api.backgroundWork.removeListener(workChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.query.trim().isEmpty ||
          people.isEmpty && !busy && !more && error == null
      ? const SizedBox.shrink()
      : Padding(
          key: const Key('actor-search-results'),
          padding: EdgeInsets.fromLTRB(
            contentInset(context),
            12,
            contentInset(context),
            12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (people.isNotEmpty)
                PeopleRail(
                  api: widget.api,
                  people: people,
                  title: '演员',
                  onItem: widget.onItem,
                ),
              if (busy)
                const Row(
                  children: [
                    CupertinoActivityIndicator(radius: 7),
                    SizedBox(width: 8),
                    Text('正在搜索演员…', style: TextStyle(fontSize: 13)),
                  ],
                ),
              if (error != null)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => load(),
                  child: const Text('演员搜索暂不可用，点击重试'),
                ),
              if (more && !busy)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => load(next: true),
                  child: const Text('加载更多演员'),
                ),
            ],
          ),
        );
}
