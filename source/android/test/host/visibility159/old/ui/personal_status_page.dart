import 'release_refresh.dart';
import 'home_visibility.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../core/personal_sync.dart';
import '../core/personal_library.dart';
import '../core/interface_preferences.dart';
import '../core/models.dart';
import 'library.dart';
import 'library_layout.dart';
import 'anchored_grid.dart';
import 'poster_actions.dart';
import 'style.dart';
import '../core/unplayed_groups.dart';

class PersonalStatusPage extends StatefulWidget {
  const PersonalStatusPage({
    super.key,
    required this.sync,
    required this.list,
    required this.onItem,
  });
  final PersonalSync sync;
  final PersonalList list;
  final Future<void> Function(MediaItem) onItem;
  @override
  State<PersonalStatusPage> createState() => _PersonalStatusPageState();
}

class _PersonalStatusPageState extends State<PersonalStatusPage> {
  List<MediaItem> items = [];
  String? error;
  bool loading = false, more = true;
  int offset = 0;
  int total = 0;
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    if (widget.list == PersonalList.favorites) {
      items = widget.sync.library.items(
        widget.sync.account,
        SavedList.favorites,
      );
    }
    scroll.addListener(onScroll);
    widget.sync.addListener(stateChanged);
    widget.sync.library.addListener(stateChanged);
    // Loading favorites notifies the shared action state. Start after mounting
    // so existing posters on the previous route are not dirtied during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (active) unawaited(load(reset: true));
    });
  }

  void onScroll() {
    // Collapsing many episodes can leave a short grid. Do not keep fetching
    // every server page merely to fill it; explicit scrolling or the footer
    // continues the same raw record pagination.
    if (widget.list == PersonalList.played &&
        scroll.hasClients &&
        !scroll.position.isScrollingNotifier.value) {
      return;
    }
    if (scroll.hasClients &&
        scroll.position.extentAfter < 400 &&
        !loading &&
        more &&
        error == null) {
      unawaited(load());
    }
  }

  void stateChanged() {
    if (!active || loading) return;
    setState(() {
      if (widget.list == PersonalList.favorites) {
        items = widget.sync.library.items(
          widget.sync.account,
          SavedList.favorites,
        );
      } else {
        items = items.map(widget.sync.latest).where((item) {
          if (!widget.sync.observed.containsKey(item.id)) return true;
          final user = object(item.data['UserData']);
          return switch (widget.list) {
            PersonalList.played => user['Played'] == true,
            PersonalList.unplayed => user['Played'] != true,
            PersonalList.likes =>
              !widget.sync.ratings.containsKey(item.id) ||
                  widget.sync.ratings[item.id] == true,
            PersonalList.dislikes =>
              !widget.sync.ratings.containsKey(item.id) ||
                  widget.sync.ratings[item.id] == false,
            _ => true,
          };
        }).toList();
      }
    });
  }

  bool get active => mounted && widget.sync.current;
  Future<void> load({bool reset = false}) async {
    if (loading || !active) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (widget.list == PersonalList.favorites) {
        await widget.sync.refreshFavorites(
          allowed: () => active && (ModalRoute.of(context)?.isCurrent ?? true),
        );
        if (!active) return;
        items = widget.sync.library.items(
          widget.sync.account,
          SavedList.favorites,
        );
        total = items.length;
        more = false;
      } else {
        final page = await widget.sync.page(
          widget.list,
          start: reset ? 0 : offset,
        );
        if (!active) return;
        final byId = {
          if (!reset)
            for (final item in items) item.id: item,
        };
        final before = byId.length;
        for (final item in page.items) {
          byId[item.id] = item;
        }
        final next = (reset ? 0 : offset) + page.items.length;
        if (next < page.total && before == byId.length) {
          throw const AppFailure('列表返回不完整，请刷新重试');
        }
        items = byId.values.toList();
        offset = next;
        total = page.total;
        more = next < total;
      }
    } catch (e) {
      if (active) error = safeError(e);
    } finally {
      if (mounted) setState(() => loading = false);
      if (active && more && error == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (active && (ModalRoute.of(context)?.isCurrent ?? false)) {
            onScroll();
          }
        });
      }
    }
  }

  Future<void> open(MediaItem item) async {
    await widget.onItem(item);
    if (active) await load(reset: true);
  }

  @override
  void dispose() {
    widget.sync.removeListener(stateChanged);
    widget.sync.library.removeListener(stateChanged);
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = PosterActionsScope.maybeOf(context);
    final permitted = HomeVisibilityScope.visible(
      context,
      widget.sync.account,
      items,
    );
    final visibleItems = switch (widget.list) {
      PersonalList.unplayed => groupUnplayed(permitted),
      PersonalList.played => groupPlayed(permitted),
      _ => permitted,
    };
    final display = phoneLayout(context)
        ? LibraryDisplay.posters
        : scope?.preferences.libraryDisplay ?? LibraryDisplay.standard;
    final metrics = LibraryGridMetrics(
      MediaQuery.sizeOf(context).width,
      MediaQuery.textScalerOf(context).scale(14) / 14,
      display,
      phone: phoneLayout(context),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text('我的${widget.list.label}'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: loading ? null : () => load(reset: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !widget.sync.current
          ? const Center(child: Text('账号已切换，请重新打开'))
          : Column(
              children: [
                VisibilityStatus(account: widget.sync.account),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.list == PersonalList.unplayed
                              ? 'Emby · 已加载 ${visibleItems.length} 部${more ? " · 继续下滑加载" : ""}'
                              : widget.list == PersonalList.played
                              ? 'Emby · ${visibleItems.length} 部${more ? "（已加载）" : ""} · $total 条已看记录'
                              : 'Emby · ${widget.list == PersonalList.favorites ? visibleItems.length : total} 项',
                          style: TextStyle(color: secondaryColor(context)),
                        ),
                      ),
                      if (loading)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: loading ? null : () => load(reset: true),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ReleaseRefresh(
                    onRefresh: () => load(reset: true),
                    child: CustomScrollView(
                      controller: scroll,
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      slivers: [
                        if (visibleItems.isEmpty && !loading)
                          const SliverFillRemaining(
                            child: Center(child: Text('暂无影片')),
                          ),
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            metrics.inset,
                            8,
                            metrics.rightInset,
                            32,
                          ),
                          sliver: AnchoredSliverGrid(
                            items: visibleItems,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: metrics.columns,
                                  mainAxisExtent: metrics.rowHeight,
                                  mainAxisSpacing: metrics.spacing,
                                  crossAxisSpacing: metrics.spacing,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) =>
                                  display == LibraryDisplay.posters
                                  ? LibraryPosterCard(
                                      item: visibleItems[index],
                                      api: widget.sync.api,
                                      onTap: () => open(visibleItems[index]),
                                      active: true,
                                    )
                                  : MediaCard(
                                      item: visibleItems[index],
                                      api: widget.sync.api,
                                      onTap: () => open(visibleItems[index]),
                                    ),
                              childCount: visibleItems.length,
                            ),
                          ),
                        ),
                        if (widget.list == PersonalList.played &&
                            more &&
                            error == null)
                          SliverToBoxAdapter(
                            child: Center(
                              child: TextButton(
                                onPressed: loading ? null : () => load(),
                                child: const Text('加载更多记录'),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
