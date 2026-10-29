import 'release_refresh.dart';
import 'poster_actions.dart';
import 'home_visibility.dart';
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../core/home_feed.dart';
import '../core/models.dart';
import 'continue_watching.dart';
import 'poster.dart';
import 'poster_art.dart';
import 'style.dart';
import 'poster_motion.dart';
import 'episode_badge.dart';
import 'scroll_to_top.dart';
import 'swipe_pages.dart';
import 'home_order.dart';
import 'surface.dart';

class HomeDashboard extends StatefulWidget {
  const HomeDashboard({
    super.key,
    required this.feed,
    required this.active,
    required this.onItem,
    required this.onPlay,
    this.onResumeAll,
    this.onResumeDetail,
    this.onSearch,
    this.reducedMotion = false,
    this.connectionRetrying = false,
  });
  final HomeFeed feed;
  final bool active;
  final bool reducedMotion;
  final bool connectionRetrying;
  final Future<void> Function(MediaItem) onItem, onPlay;
  final VoidCallback? onResumeAll;
  final VoidCallback? onSearch;
  final Future<void> Function(MediaItem)? onResumeDetail;
  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard>
    with WidgetsBindingObserver {
  Timer? timer;
  Future<void>? refreshJob;
  bool foreground = true, routeCurrent = false;
  final scroll = ScrollController();
  void schedule() {
    timer?.cancel();
    if (!foreground ||
        !widget.active ||
        !routeCurrent ||
        widget.feed.browse == null ||
        widget.feed.api.backgroundWork.paused) {
      return;
    }
    timer = Timer(widget.feed.browse!.preferences.interval, () async {
      if (mounted &&
          foreground &&
          widget.active &&
          ModalRoute.of(context)?.isCurrent == true) {
        await refresh();
      } else if (mounted) {
        schedule();
      }
    });
  }

  Future<void> refresh({bool force = false}) {
    if (refreshJob != null && !force) return refreshJob!;
    timer?.cancel();
    late final Future<void> task;
    task = widget.feed.refresh(force: force).whenComplete(() {
      if (identical(refreshJob, task)) {
        refreshJob = null;
        if (mounted) schedule();
      }
    });
    return refreshJob = task;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.feed.browse?.preferences.addListener(schedule);
    widget.feed.api.backgroundWork.addListener(schedule);
    unawaited(refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeCurrent =
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled;
    schedule();
  }

  @override
  void dispose() {
    timer?.cancel();
    scroll.dispose();
    widget.feed.browse?.preferences.removeListener(schedule);
    widget.feed.api.backgroundWork.removeListener(schedule);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HomeDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    schedule();
    if (widget.active && !oldWidget.active) {
      unawaited(refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    schedule();
    if (state == AppLifecycleState.resumed &&
        widget.active &&
        ModalRoute.of(context)?.isCurrent == true) {
      unawaited(refresh());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.feed, widget.feed.api.connection]),
    builder: (context, _) {
      final feed = widget.feed;
      final sections = feed.displaySections;
      final visibility = feed.store.homeOrder;
      final resolving = !visibility.ready(feed.account);
      final readError =
          feed.error ??
          [
            if (feed.resumeError != null) '继续观看：${feed.resumeError}',
            for (final section in sections)
              if (section.error != null)
                '${section.library.title}：${section.error}',
          ].join('\n');
      return PosterMotionScope(
        active: widget.active,
        reducedMotion: widget.reducedMotion,
        child: Column(
          children: [
            SectionHeading(
              '首页',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  headerAction(
                    'home-search',
                    '搜索',
                    CupertinoIcons.search,
                    widget.onSearch,
                  ),
                  headerAction(
                    'home-order',
                    '分区排序',
                    CupertinoIcons.line_horizontal_3_decrease,
                    () => showSurface<void>(
                      context,
                      (_) => HomeOrderPage(feed: feed),
                    ),
                  ),
                  headerAction(
                    'home-refresh',
                    '刷新首页',
                    CupertinoIcons.refresh,
                    feed.loading ? null : () => refresh(force: true),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ScrollToTop(
                controller: scroll,
                bottom:
                    browseBottomSpace(context, wide: 20) -
                    (wideLayout(context) ? 0 : 6),
                child: ReleaseRefreshScrollView(
                  onRefresh: () => refresh(force: true),
                  busy: feed.loading,
                  key: const PageStorageKey('home-feed'),
                  controller: scroll,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(300),
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  slivers: [
                    if (resolving)
                      SliverToBoxAdapter(
                        child: MessagePanel(
                          visibility.visibilityError(feed.account) ??
                              '正在核对分区可见范围',
                          busy:
                              visibility.visibilityError(feed.account) == null,
                          retry:
                              visibility.visibilityError(feed.account) ==
                                      null ||
                                  readError.isNotEmpty ||
                                  !allowSectionRetry
                              ? null
                              : () =>
                                    feed.browse?.ensureVisibility(force: true),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: ContinueWatching(
                        feed: feed,
                        active: widget.active,
                        allowRetry: false,
                        showError: false,
                        onPlay: widget.onPlay,
                        onDetail: widget.onResumeDetail ?? widget.onItem,
                        onViewAll: widget.onResumeAll,
                      ),
                    ),
                    if (readError.isNotEmpty)
                      SliverToBoxAdapter(
                        child: MessagePanel(
                          readError,
                          retry: allowSectionRetry ? feed.retry : null,
                        ),
                      ),
                    if (!resolving &&
                        feed.error == null &&
                        (sections.isEmpty ||
                            (!feed.loading &&
                                HomeVisibilityScope.visible(
                                  context,
                                  feed.account,
                                  feed.resume,
                                ).isEmpty &&
                                feed.resumeError == null &&
                                sections.every(
                                  (section) =>
                                      !section.loading &&
                                      section.error == null &&
                                      HomeVisibilityScope.visible(
                                        context,
                                        feed.account,
                                        section.items,
                                      ).isEmpty,
                                ))))
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: MessagePanel(
                          feed.loading
                              ? '正在读取首页'
                              : sections.isEmpty && feed.sections.isNotEmpty
                              ? '首页分区已隐藏，可在分区排序中开启'
                              : '没有可显示的媒体库',
                          busy: feed.loading,
                          icon: CupertinoIcons.rectangle_stack,
                        ),
                      ),
                    SliverList.builder(
                      itemCount: sections.length,
                      itemBuilder: (context, index) => section(sections[index]),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: browseBottomSpace(context, wide: 32),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  Widget headerAction(
    String id,
    String label,
    IconData icon,
    VoidCallback? action,
  ) => Semantics(
    label: label,
    button: true,
    child: CupertinoButton(
      key: ValueKey(id),
      padding: EdgeInsets.zero,
      minimumSize: const Size(44, 44),
      onPressed: action,
      child: id == 'home-order'
          ? SizedBox(
              width: phoneValue(context, 23, 26),
              height: phoneValue(context, 23, 26),
              child: const FittedBox(child: HomeSectionOrderIcon()),
            )
          : Icon(
              icon,
              size: phoneValue(context, 23, 26),
              color: action == null
                  ? secondaryColor(context)
                  : accentColor(context),
            ),
    ),
  );

  bool get allowSectionRetry =>
      !widget.connectionRetrying && !widget.feed.api.connection.hasProblem;
  Widget section(HomeSection section) {
    final items = HomeVisibilityScope.visible(
      context,
      widget.feed.account,
      section.items,
    );
    if (!section.loading && section.error == null && items.isEmpty) {
      return const SizedBox.shrink();
    }
    final textScale = MediaQuery.textScalerOf(context).scale(13) / 13;
    final posterWidth = shelfPosterWidth(context);
    return Column(
      key: ValueKey('home-latest-${section.library.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            contentInset(context),
            phoneValue(context, 2, 8),
            12,
            phoneValue(context, 4, 12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '最新${section.library.title}',
                  style: TextStyle(
                    fontSize: phoneValue(context, 17, 20),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: () => widget.onItem(section.library),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('查看全部', style: TextStyle(fontSize: 13)),
                    SizedBox(width: 4),
                    Icon(CupertinoIcons.chevron_forward, size: 13),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (section.loading && items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: CupertinoActivityIndicator(),
          ),
        if (items.isNotEmpty)
          HorizontalPageSwipeBoundary(
            child: SizedBox(
              height: phoneLayout(context)
                  ? posterWidth / posterAspectRatio + 10 + 34 * textScale
                  : 194 + 34 * textScale,
              child: ListView.separated(
                key: PageStorageKey('latest-${section.library.id}'),
                scrollDirection: Axis.horizontal,
                scrollCacheExtent: const ScrollCacheExtent.pixels(272),
                padding: EdgeInsets.symmetric(
                  horizontal: contentInset(context),
                ),
                itemCount: items.length,
                separatorBuilder: (_, _) =>
                    SizedBox(width: phoneValue(context, 12, 16)),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return PosterEntrance(
                    key: ValueKey('latest-${section.library.id}-${item.id}'),
                    id: 'latest:${section.library.id}:${item.id}',
                    active: widget.active,
                    axis: Axis.horizontal,
                    child: SizedBox(
                      width: posterWidth,
                      child: Semantics(
                        button: true,
                        child: GestureDetector(
                          onTap: () => widget.onItem(item),
                          behavior: HitTestBehavior.opaque,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  phoneLayout(context) ? 14 : 4,
                                ),
                                child: SizedBox(
                                  width: posterWidth,
                                  height: posterWidth / posterAspectRatio,
                                  child: PosterActionRegion(
                                    item: item,
                                    externalMenu: true,
                                    active: widget.active,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Poster(
                                          url: posterUrl(widget.feed.api, item),
                                          active: widget.active,
                                        ),
                                        EpisodeBadge(item: item),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              PosterActionTitle(
                                item: item,
                                active: widget.active,
                                child: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
