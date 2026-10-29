import 'release_refresh.dart';
import 'home_visibility.dart';
import 'actor_search_results.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show IconButton;
import 'package:flutter/rendering.dart'
    show ScrollCacheExtent, RenderSliverGrid;
import '../core/alphabet.dart';
import '../core/catalog.dart';
import '../core/catalog_filters.dart';
import '../core/catalog_projection.dart';
import 'filter_chips.dart';
import 'expansion_chevron.dart';
import '../core/catalog_sort.dart';
import '../core/browse_cache.dart';
import '../core/emby.dart';
import '../core/home_feed.dart';
import '../core/personal_sync.dart';
import 'poster_actions.dart';
import 'resume_menu.dart';
import 'anchored_grid.dart';
import '../core/background_work.dart';
import '../core/models.dart';
import '../core/interface_preferences.dart';
import 'library_layout.dart';
import 'library.dart' show MediaCard;
import 'style.dart';
import 'alphabet_rail.dart';
import 'poster_motion.dart';
import 'scroll_to_top.dart';
import 'catalog_sort_menu.dart';
import 'browse_menu.dart';
import 'swipe_pages.dart';
import '../core/version_groups.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.api,
    required this.onItem,
    this.active = true,
    this.parent,
    this.browse,
    this.resumeFeed,
    this.onRefreshAll,
    this.refreshFeed,
    this.onPlay,
    this.reducedMotion = false,
    this.requestedLibrary,
    this.libraryRequest = 0,
    this.display = LibraryDisplay.standard,
    this.searchMode = false,
  });
  final EmbyClient api;
  final LibraryDisplay display;
  final bool searchMode;
  final Future<void> Function(MediaItem) onItem;
  final bool active;
  final bool reducedMotion;
  final MediaItem? parent;
  final MediaItem? requestedLibrary;
  final int libraryRequest;
  final BrowseRepository? browse;
  final HomeFeed? resumeFeed;
  final HomeFeed? refreshFeed;
  final Future<void> Function()? onRefreshAll;
  final Future<void> Function(MediaItem)? onPlay;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _BrowseView {
  _BrowseView(
    this.items,
    this.offset,
    this.more,
    this.scroll,
    this.search,
    this.sort,
    this.descending,
    this.played,
    this.parentId,
    this.firstPageKeys,
    this.alphabet,
    this.indexItems,
    this.indexComplete,
    this.indexTotal,
    this.filters,
  );
  final List<MediaItem> items;
  final int offset;
  final bool more;
  final double scroll;
  final String search, sort;
  final bool descending;
  final bool? played;
  final String? parentId;
  final Set<String> firstPageKeys;
  final bool alphabet, indexComplete;
  final List<MediaItem> indexItems;
  final int indexTotal;
  final CatalogFilters filters;
}

final _views = Expando<Map<String, _BrowseView>>();
final _viewRevisions = Expando<int>();

class _LibraryPageState extends State<LibraryPage> with WidgetsBindingObserver {
  final search = TextEditingController();
  final searchFocus = FocusNode();
  CatalogFilters filters = const CatalogFilters();
  final gridKey = GlobalKey();
  final sortButtonKey = GlobalKey();
  final libraryButtonKey = GlobalKey();
  final browseMenu = BrowseMenuController();
  final visibleLetter = ValueNotifier<String?>(null);
  List<MediaItem> visibleItems = const [];
  int gridColumns = 1;
  double gridStride = 156;
  bool letterUpdateScheduled = false;

  void syncVisibleLetter() {
    if (!alphabet || letterUpdateScheduled) return;
    letterUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      letterUpdateScheduled = false;
      if (!mounted || !alphabet) return;
      final grid = gridKey.currentContext?.findRenderObject();
      if (visibleItems.isEmpty) {
        visibleLetter.value = null;
      } else if (grid is RenderSliverGrid && grid.geometry != null) {
        // Sliver-local offset includes refresh displacement and responds to
        // rotation, text scaling and restored scroll positions after layout.
        final row = (grid.constraints.scrollOffset / gridStride).floor();
        final at =
            scroll.hasClients &&
                scroll.position.maxScrollExtent > 0 &&
                scroll.position.extentAfter < .5
            ? visibleItems.length - 1
            : (row * gridColumns).clamp(0, visibleItems.length - 1);
        final previous = visibleLetter.value;
        final rowHasPrevious = visibleItems
            .skip(at)
            .take(gridColumns)
            .any((item) => titleLetter(item.title) == previous);
        visibleLetter.value = rowHasPrevious
            ? previous
            : titleLetter(visibleItems[at].title);
      }
    });
  }

  late final ScrollController scroll;
  final items = <MediaItem>[];
  Set<String> firstPageKeys = {};
  String pageKey(MediaItem item) => resumeMode ? resumeTitleKey(item) : item.id;
  List<MediaItem> libraries = [];
  String? parentId, error;
  String sort = '';
  bool descending = false;
  final catalogOrdering = CatalogOrdering();
  List<MediaItem>? orderedSource;
  List<MediaItem> orderedItems = [];
  String? orderedSort;
  bool? orderedDescending;
  bool? played;
  bool busy = false, more = true, initialized = false, foreground = true;
  bool alphabet = false, indexing = false, indexComplete = false;
  bool filtering = false;
  final indexItems = <MediaItem>[];
  int indexTotal = 0, indexRevision = 0;
  List<MediaItem> catalogShown = [];
  void applyProjection(CatalogView value) {
    catalogShown = value.items;
    letterOffsets = value.offsets;
  }

  Map<String, int> letterOffsets = {};
  int filterRevision = 0, jumpRevision = 0;
  int revision = 0, offset = 0;
  int cacheRevision = 0;
  Timer? debounce, timer;
  DateTime? lastProgress;
  bool refreshingProgress = false;
  Future<void>? refreshJob, catalogJob, manualRefreshJob;
  int connectionRecovery = 0;
  PersonalSync? personalSync;
  int personalRevision = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = PosterActionsScope.maybeOf(context)?.sync;
    if (identical(next, personalSync)) return;
    personalSync?.removeListener(personalChanged);
    personalSync = next;
    personalRevision = next?.revision ?? 0;
    next?.addListener(personalChanged);
  }

  void personalChanged() {
    final sync = personalSync;
    if (!mounted ||
        sync == null ||
        !sync.current ||
        sync.revision == personalRevision) {
      return;
    }
    personalRevision = sync.revision;
    var changed = false;
    for (final list in [items, indexItems]) {
      for (var at = 0; at < list.length; at++) {
        final fresh = sync.changedItem;
        if (fresh == null || fresh.id != list[at].id) continue;
        list[at] = MediaItem({
          ...list[at].data,
          'UserData': fresh.data['UserData'],
        });
        changed = true;
      }
    }
    if (!changed) return;
    if (catalogMode) {
      unawaited(filterCatalog(changed: true));
    } else {
      setState(() {
        if (played != null) {
          items.removeWhere(
            (item) =>
                (object(item.data['UserData'])['Played'] == true) != played,
          );
        }
      });
    }
  }

  bool recoveryPending = false;
  void connectionChanged() {
    final recovered = widget.api.connection.recovery;
    if (recovered <= connectionRecovery) return;
    connectionRecovery = recovered;
    widget.browse?.connectionRecovered();
    if (error != null || !initialized || !indexComplete) recoveryPending = true;
    optionalWorkChanged();
  }

  void optionalWorkChanged() {
    schedule();
    if (!widget.api.backgroundWork.paused && visible && recoveryPending) {
      recoveryPending = false;
      unawaited(initialized ? refreshCurrent() : initialize());
    }
  }

  bool get resumeMode => widget.resumeFeed != null;
  bool get catalogMode => !resumeMode && widget.browse != null;
  bool get needsSortMetadata =>
      (sort == 'PremiereDate' || sort == 'CommunityRating') &&
      indexItems.any(
        (item) =>
            item.data['_YingyuSortMetadataV2'] != true &&
            catalogSortValue(item, sort) == null,
      );
  String get viewKey => widget.searchMode
      ? 'home-search'
      : resumeMode
      ? 'resume'
      : 'library:${widget.parent?.id ?? "all"}';
  bool get visible =>
      mounted &&
      widget.active &&
      foreground &&
      (ModalRoute.of(context)?.isCurrent ?? true);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.resumeFeed?.addListener(resumeChanged);
    widget.refreshFeed?.addListener(sharedRefreshChanged);
    connectionRecovery = widget.api.connection.recovery;
    widget.api.connection.addListener(connectionChanged);
    widget.api.backgroundWork.addListener(optionalWorkChanged);
    parentId = widget.parent?.id;
    final preferred = widget.browse?.preferences.sort ?? '';
    alphabet = !resumeMode && preferred == 'alphabet';
    sort = preferred == 'alphabet' || resumeMode ? '' : preferred;
    descending = widget.browse?.preferences.descending ?? false;
    libraries = widget.browse?.peek('views')?.items ?? [];
    final repository = widget.browse;
    cacheRevision = repository?.reconciliationRevision ?? 0;
    if (repository != null &&
        _viewRevisions[repository] != repository.reconciliationRevision) {
      _views[repository]?.clear();
      _viewRevisions[repository] = repository.reconciliationRevision;
    }
    final saved = widget.browse == null
        ? null
        : _views[widget.browse!]?[viewKey];
    if (saved != null) {
      items.addAll(saved.items);
      firstPageKeys = Set.of(saved.firstPageKeys);
      offset = saved.offset;
      more = saved.more;
      sort = saved.sort;
      descending = saved.descending;
      played = saved.played;
      parentId = saved.parentId;
      initialized = true;
      alphabet = saved.alphabet;
      indexItems.addAll(saved.indexItems);
      indexComplete = saved.indexComplete;
      indexTotal = saved.indexTotal;
      filters = saved.filters;
      if (indexItems.length <= 512) {
        applyProjection(selectCurrentCatalog(orderedCatalog()));
      }
    } else if (resumeMode) {
      items.addAll(widget.resumeFeed!.resume);
    }
    if (saved == null && catalogMode) {
      final cached = widget.browse!.peekSharedCatalogue(parentId);
      if (cached != null) {
        indexItems.addAll(cached.items);
        if (indexItems.length <= 512) {
          applyProjection(selectCurrentCatalog(orderedCatalog()));
        }
        indexTotal = cached.total;
        indexComplete = true;
        initialized = widget.browse!.fresh(cached);
      }
    }
    if (!initialized && !resumeMode && !alphabet) {
      items.addAll(
        widget.browse
                ?.peek(
                  BrowseRepository.browseKey(
                    parentId,
                    '',
                    0,
                    sort,
                    null,
                    false,
                  ),
                )
                ?.items ??
            [],
      );
    }
    scroll = ScrollController(initialScrollOffset: saved?.scroll ?? 0)
      ..addListener(() {
        syncVisibleLetter();
        if (!catalogMode && scroll.position.extentAfter < 240 && visible) {
          unawaited(load());
        }
      });
    if (catalogMode && indexItems.length > 512) unawaited(filterCatalog());
    widget.browse?.preferences.addListener(schedule);
    schedule();
    if (widget.active) unawaited(initialize());
    if (widget.searchMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) searchFocus.requestFocus();
      });
    }
  }

  void schedule() {
    timer?.cancel();
    if (widget.browse == null || widget.api.backgroundWork.paused) return;
    timer = Timer(widget.browse!.preferences.interval, () async {
      if (visible) {
        await refreshCurrent();
      } else if (mounted) {
        schedule();
      }
    });
  }

  Future<void> refreshCurrent({bool reconcile = false}) {
    if (reconcile) {
      return manualRefreshJob ??= () async {
        await refreshJob;
        await catalogJob;
        if (mounted) await _refreshCurrent(reconcile: true);
      }().whenComplete(() => manualRefreshJob = null);
    }
    return manualRefreshJob ?? _refreshCurrent();
  }

  Future<void> _refreshCurrent({bool reconcile = false}) {
    if (refreshJob != null) return refreshJob!;
    if (!visible || widget.api.backgroundWork.paused) return Future.value();
    timer?.cancel();
    final task = () async {
      final all = reconcile ? widget.onRefreshAll : null;
      try {
        if (all != null) {
          await all();
          if (!visible || widget.api.backgroundWork.paused) return;
          if (widget.parent == null && !resumeMode) {
            final fresh = await widget.browse!.libraries();
            if (!visible) return;
            setState(() {
              libraries = fresh;
              if (parentId != null && !fresh.any((e) => e.id == parentId)) {
                parentId = null;
              }
            });
          }
        }
        if (catalogMode) {
          await buildIndex(
            refresh: true,
            force: all == null,
            resourceSnapshot: reconcile && all == null,
          );
        } else {
          await refreshInPlace(force: true);
        }
      } catch (e) {
        if (e is! BackgroundPaused && visible) {
          setState(() => error = safeError(e));
        }
        return;
      }
      if (reconcile && visible && error == null && widget.browse != null) {
        try {
          if (all == null) await widget.browse!.finishLocalSync();
          _views[widget.browse!]?.clear();
          _viewRevisions[widget.browse!] =
              widget.browse!.reconciliationRevision;
          cacheRevision = widget.browse!.reconciliationRevision;
        } catch (e) {
          if (visible) setState(() => error = safeError(e));
        }
      }
    }();
    return refreshJob = task.whenComplete(() {
      refreshJob = null;
      if (mounted) {
        schedule();
        sharedRefreshChanged();
      }
    });
  }

  void remember() {
    final repo = widget.browse;
    if (repo == null || cacheRevision != repo.reconciliationRevision) return;
    final state = _views[repo] ??= {};
    state[viewKey] = _BrowseView(
      List.of(items),
      offset,
      more,
      scroll.hasClients ? scroll.offset : 0,
      '',
      sort,
      descending,
      played,
      parentId,
      Set.of(firstPageKeys),
      alphabet,
      List.of(indexItems),
      indexComplete,
      indexTotal,
      filters,
    );
    if (state.length > 16) state.remove(state.keys.first);
  }

  @override
  void dispose() {
    personalSync?.removeListener(personalChanged);
    widget.resumeFeed?.removeListener(resumeChanged);
    widget.refreshFeed?.removeListener(sharedRefreshChanged);
    remember();
    revision++;
    indexRevision++;
    filterRevision++;
    WidgetsBinding.instance.removeObserver(this);
    widget.api.connection.removeListener(connectionChanged);
    widget.api.backgroundWork.removeListener(optionalWorkChanged);
    widget.browse?.preferences.removeListener(schedule);
    timer?.cancel();
    debounce?.cancel();
    search.dispose();
    searchFocus.dispose();
    scroll.dispose();
    visibleLetter.dispose();
    super.dispose();
  }

  bool sharedRefreshQueued = false;
  void sharedRefreshChanged() {
    if (!mounted || sharedRefreshQueued) return;
    sharedRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      sharedRefreshQueued = false;
      if (!mounted) return;
      setState(() {});
      final repo = widget.browse;
      if (visible &&
          repo != null &&
          cacheRevision != repo.reconciliationRevision &&
          refreshJob == null &&
          manualRefreshJob == null) {
        cacheRevision = repo.reconciliationRevision;
        unawaited(refreshCurrent());
      }
    });
  }

  void resumeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshFeed != widget.refreshFeed) {
      oldWidget.refreshFeed?.removeListener(sharedRefreshChanged);
      widget.refreshFeed?.addListener(sharedRefreshChanged);
    }
    if (oldWidget.resumeFeed != widget.resumeFeed) {
      oldWidget.resumeFeed?.removeListener(resumeChanged);
      widget.resumeFeed?.addListener(resumeChanged);
    }
    if (widget.libraryRequest != oldWidget.libraryRequest) {
      parentId = widget.requestedLibrary?.id;
      search.clear();
      played = null;
      filters = const CatalogFilters();
      libraries = widget.browse?.peek('views')?.items ?? libraries;
      initialized = true;
      unawaited(reset());
      return;
    }
    if (!widget.active) {
      leaveSearch();
      indexRevision++;
      indexing = false;
    }
    if (widget.active && !oldWidget.active) {
      optionalWorkChanged();
      if (widget.browse != null &&
          cacheRevision != widget.browse!.reconciliationRevision) {
        cacheRevision = widget.browse!.reconciliationRevision;
        unawaited(refreshCurrent());
        return;
      }
      if (!initialized) {
        unawaited(initialize());
      } else {
        unawaited(refreshProgress());
        if (catalogMode && !indexComplete) unawaited(buildIndex());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      indexRevision++;
      indexing = false;
    }
    if (visible) {
      optionalWorkChanged();
      unawaited(refreshProgress());
      if (catalogMode && !indexComplete) unawaited(buildIndex());
    }
  }

  Future<void> initialize() async {
    if (!widget.active) return;
    if (widget.parent == null && !resumeMode) {
      try {
        final value =
            await (widget.browse?.libraries() ?? widget.api.libraries());
        if (mounted) setState(() => libraries = value);
      } catch (e) {
        if (e is BackgroundPaused) return;
        if (mounted) setState(() => error = safeError(e));
        if (items.isEmpty && indexItems.isEmpty && libraries.isEmpty) return;
      }
    }
    if (!initialized) {
      initialized = true;
      error = null;
      catalogMode
          ? await buildIndex(refresh: indexComplete, force: false)
          : await load();
    }
    if (mounted) schedule();
  }

  Future<ItemPage> page({int? at, bool force = false}) {
    final start = at ?? offset;
    final requestRevision = revision;
    if (resumeMode) {
      return widget.browse?.resume(start: start, limit: 48, force: force) ??
          widget.api.resumeItems(start: start, limit: 48);
    }
    return widget.browse?.items(
          parent: parentId,
          search: search.text.trim(),
          start: start,
          sort: sort,
          played: played,
          force: force,
          allowed: () => visible && requestRevision == revision,
        ) ??
        widget.api.browseItems(
          parent: parentId,
          search: search.text.trim(),
          start: start,
          sort: sort,
          played: played,
        );
  }

  Future<void> reset() async {
    revision++;
    final requestRevision = revision;
    indexRevision++;
    indexing = false;
    indexItems.clear();
    catalogShown = [];
    letterOffsets = {};
    filterRevision++;
    indexComplete = false;
    orderedSource = null;
    final cached = widget.browse?.peekSharedCatalogue(parentId);
    if (catalogMode && cached != null) {
      indexItems.addAll(cached.items);
      indexTotal = cached.total;
      await filterCatalog(changed: true);
      if (!mounted || requestRevision != revision) return;
      indexComplete = widget.browse!.fresh(cached);
    }
    busy = false;
    more = true;
    offset = 0;
    setState(() {
      items.clear();
      error = null;
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    catalogMode ? await buildIndex() : await load();
  }

  Future<void> load() async {
    if (busy || !more || error != null || !mounted || !widget.active) return;
    final requestRevision = revision;
    setState(() => busy = true);
    try {
      final value = await page();
      if (!mounted || requestRevision != revision) return;
      setState(() {
        if (offset == 0) firstPageKeys = value.items.map(pageKey).toSet();
        error = null;
        final merged = offset == 0 && resumeMode
            ? widget.resumeFeed!.mergeResume(value.items, limit: 1000000)
            : offset == 0
            ? value.items
            : [...items, ...value.items];
        items.clear();
        if (resumeMode) {
          items.addAll(collapseResume(merged, limit: 1000000));
        } else {
          final ids = <String>{};
          items.addAll(merged.where((item) => ids.add(item.id)));
        }
        offset += value.items.length;
        more =
            value.items.isNotEmpty &&
            (value.total > 0 ? offset < value.total : value.items.length == 48);
      });
    } catch (e) {
      if (e is! BackgroundPaused && mounted && requestRevision == revision) {
        setState(() => error = safeError(e));
      }
    } finally {
      if (mounted && requestRevision == revision) setState(() => busy = false);
    }
  }

  Future<void> refreshInPlace({bool force = false}) async {
    if (busy || !visible || catalogMode) return;
    final requestRevision = revision;
    setState(() => busy = true);
    try {
      final value = await page(at: 0, force: force);
      if (!mounted || requestRevision != revision) return;
      final byId = {for (final item in value.items) item.id: item};
      setState(() {
        if (!scroll.hasClients || scroll.offset < 1) {
          // A raw page may collapse to fewer than 48 series. Track its keys
          // instead of dropping 48 displayed rows and losing later pages.
          final old = offset <= 48
              ? <MediaItem>[]
              : items
                    .where((item) => !firstPageKeys.contains(pageKey(item)))
                    .toList();
          final head = resumeMode
              ? widget.resumeFeed!.mergeResume(value.items, limit: 1000000)
              : value.items;
          final merged = [...head, ...old];
          firstPageKeys = value.items.map(pageKey).toSet();
          final ids = <String>{};
          items
            ..clear()
            ..addAll(
              resumeMode
                  ? collapseResume(merged, limit: 1000000)
                  : merged.where((item) => ids.add(item.id)),
            );
          if (offset <= 48) {
            offset = value.items.length;
            more = value.total > 0
                ? offset < value.total
                : value.items.length == 48;
          }
        } else {
          for (var i = 0; i < items.length; i++) {
            items[i] = byId[items[i].id] ?? items[i];
          }
        }
        error = null;
      });
    } catch (e) {
      if (e is! BackgroundPaused && mounted && requestRevision == revision) {
        setState(() => error = safeError(e));
      }
    } finally {
      if (mounted && requestRevision == revision) setState(() => busy = false);
    }
  }

  Future<void> refreshProgress() async {
    if (widget.browse != null) {
      // The scheduled metadata refresh is cache-aware. Do not issue one request
      // per previously loaded page merely because the app came to foreground.
      if (lastProgress != null &&
          DateTime.now().difference(lastProgress!) <
              widget.browse!.preferences.interval) {
        return;
      }
      lastProgress = DateTime.now();
      await refreshInPlace();
      return;
    }
    if (busy || refreshingProgress || items.isEmpty) return;
    refreshingProgress = true;
    final generation = revision;
    try {
      final values = await widget.api.backgroundWork.run(
        () => widget.api.progressItems(
          items.take(48).map((item) => item.id).toList(),
        ),
      );
      if (!mounted || generation != revision || !widget.active) return;
      final byId = {for (final value in values) value.id: value};
      setState(() {
        for (var i = 0; i < items.length; i++) {
          final fresh = byId[items[i].id];
          if (fresh != null) {
            items[i] = MediaItem({
              ...items[i].data,
              if (fresh.data.containsKey('UserData'))
                'UserData': fresh.data['UserData'],
              for (final field in [
                'ProductionYear',
                'PremiereDate',
                'CommunityRating',
                'DateCreated',
              ])
                if (fresh.data.containsKey(field)) field: fresh.data[field],
              if (fresh.data.containsKey('RunTimeTicks'))
                'RunTimeTicks': fresh.data['RunTimeTicks'],
            });
          }
        }
      });
    } catch (e) {
      if (e is! BackgroundPaused && mounted) {
        setState(() => error = safeError(e));
      }
    } finally {
      refreshingProgress = false;
    }
  }

  Future<void> choose(MediaItem item) async {
    // Opening a result is part of this search. Only leaving the browsing page
    // clears the temporary query; detail/back must preserve results and offset.
    dismissSearch();
    indexRevision++;
    indexing = false;
    await widget.onItem(item);
    // Returning from detail preserves the list, filter and exact scroll offset.
    // Apply a newer displayed checkpoint already fetched by the existing player.
    final versions = item is VersionGroup ? item.versions : [item];
    final updates = <String, MediaItem>{
      for (final version in versions)
        if (widget.browse?.peek('detail:${version.id}')?.items.firstOrNull
            case final MediaItem fresh)
          version.id: fresh,
    };
    if (mounted && updates.isNotEmpty) {
      setState(() {
        for (final list in [items, indexItems]) {
          for (var at = 0; at < list.length; at++) {
            final fresh = updates[list[at].id];
            if (fresh == null) continue;
            list[at] = MediaItem({
              ...list[at].data,
              'UserData': fresh.data['UserData'],
              for (final field in [
                'ProductionYear',
                'PremiereDate',
                'CommunityRating',
                'DateCreated',
              ])
                if (fresh.data.containsKey(field)) field: fresh.data[field],
            });
          }
        }
      });
      if (catalogMode) unawaited(filterCatalog(changed: true));
    }
    if (mounted && catalogMode && !indexComplete) unawaited(buildIndex());
  }

  void leaveSearch() {
    dismissSearch();
    debounce?.cancel();
    if (search.text.isEmpty) return;
    search.clear();
    revision++;
    filterRevision++;
    if (catalogMode) {
      unawaited(filterCatalog());
    } else {
      items.clear();
      initialized = false;
      offset = 0;
      more = true;
      if (mounted) setState(() {});
    }
  }

  List<MediaItem> orderedCatalog() {
    final key = alphabet ? 'alphabet' : normalizeCatalogSort(sort);
    if (orderedSource == null ||
        orderedSort != key ||
        orderedDescending != descending) {
      orderedItems = catalogOrdering.apply(indexItems, key, descending);
      orderedSource = indexItems;
      orderedSort = key;
      orderedDescending = descending;
    }
    return orderedItems;
  }

  CatalogView selectCurrentCatalog(List<MediaItem> source) => projectCatalog((
    source,
    search.text,
    played,
    widget.searchMode ? filters : null,
    widget.browse?.account ?? widget.api.session!,
  ));

  Future<void> filterCatalog({bool changed = false}) async {
    if (changed) orderedSource = null;
    final token = ++filterRevision;
    if (indexItems.length > 512) setState(() => filtering = true);
    try {
      final key = alphabet ? 'alphabet' : normalizeCatalogSort(sort);
      if (indexItems.length > 512 &&
          (orderedSource == null ||
              orderedSort != key ||
              orderedDescending != descending)) {
        final sorted = await compute(orderCatalog, (
          List<MediaItem>.of(indexItems),
          key,
          descending,
        ));
        if (!mounted || token != filterRevision) return;
        orderedItems = sorted;
        orderedSource = indexItems;
        orderedSort = key;
        orderedDescending = descending;
      }
      final source = orderedCatalog();
      final result = indexItems.length <= 512
          ? selectCurrentCatalog(source)
          : await compute(projectCatalog, (
              source,
              search.text,
              played,
              widget.searchMode ? filters : null,
              widget.browse?.account ?? widget.api.session!,
            ));
      if (!mounted || token != filterRevision) return;
      setState(() {
        applyProjection(result);
      });
    } catch (e) {
      if (mounted && token == filterRevision) {
        setState(() => error = safeError(e));
      }
    } finally {
      if (mounted && token == filterRevision && filtering) {
        setState(() => filtering = false);
      }
    }
  }

  Future<void> buildIndex({
    bool refresh = false,
    bool? force,
    bool resourceSnapshot = false,
  }) {
    if (indexing && catalogJob != null) return catalogJob!;
    return catalogJob = loadCatalog(
      refresh: refresh,
      force: force,
      resourceSnapshot: resourceSnapshot,
    );
  }

  Future<void> loadCatalog({
    bool refresh = false,
    bool? force,
    bool resourceSnapshot = false,
  }) async {
    final repo = widget.browse;
    if (repo == null ||
        indexing ||
        (indexComplete && !refresh && !needsSortMetadata)) {
      return;
    }
    final token = ++indexRevision;
    setState(() {
      indexing = true;
    });
    try {
      final page = await repo.catalogue(
        parent: parentId,
        sort: 'alphabet',
        force: (force ?? refresh) || needsSortMetadata,
        resourceSnapshot: resourceSnapshot,
        allowed: () => mounted && visible && token == indexRevision,
      );
      if (!mounted || !visible || token != indexRevision) return;
      setState(() {
        indexItems
          ..clear()
          ..addAll(page.items);
        indexTotal = page.total;
        indexComplete = true;
        error = null;
      });
      await filterCatalog(changed: true);
    } catch (e) {
      if (e is! BackgroundPaused && mounted && token == indexRevision) {
        setState(() => error = safeError(e));
      }
    } finally {
      if (mounted && token == indexRevision) {
        setState(() => indexing = false);
        // Manual, automatic and initial catalogue loads share one completion
        // point. The next interval starts here instead of at the old deadline.
        schedule();
      }
    }
  }

  Future<void> sorting() async {
    dismissSearch();
    final current = alphabet ? 'alphabet' : normalizeCatalogSort(sort);
    final value = await showCatalogSortMenu(
      context,
      controller: browseMenu,
      anchor: sortButtonKey,
      sort: current,
      descending: descending,
      played: played,
    );
    if (!mounted || value == null) return;
    if (value.startsWith('played:')) {
      final nextPlayed = value == 'played:all' ? null : value == 'played:true';
      if (played == nextPlayed) return;
      setState(() => played = nextPlayed);
      if (scroll.hasClients) scroll.jumpTo(0);
      if (catalogMode) {
        await filterCatalog();
      } else {
        await reset();
      }
      return;
    }
    final nextSort = value.startsWith('sort:') ? value.substring(5) : current;
    final nextDescending = value.startsWith('order:')
        ? value == 'order:descending'
        : descending;
    if (current == nextSort && descending == nextDescending) return;
    try {
      await widget.browse?.preferences.setSort(
        nextSort,
        descending: nextDescending,
      );
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
      return;
    }
    if (!mounted) return;
    setState(() {
      alphabet = nextSort == 'alphabet';
      sort = alphabet ? '' : nextSort;
      descending = nextDescending;
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    if (catalogMode) {
      await filterCatalog();
      if (needsSortMetadata) await buildIndex(refresh: true);
    } else {
      await reset();
    }
  }

  void dismissSearch() {
    searchFocus.unfocus(disposition: UnfocusDisposition.scope);
    // Overlay focus restoration must not reopen the keyboard. Only a new tap
    // inside the search field makes it focusable again.
    searchFocus.canRequestFocus = false;
  }

  bool libraryOpen = false;
  bool libraryOpensUp = false;
  Widget libraryPicker() => Row(
    children: [
      Flexible(
        flex: 0,
        child: Container(
          key: libraryButtonKey,
          child: CupertinoButton(
            key: const Key('library-picker'),
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 42),
            onPressed: () async {
              dismissSearch();
              if (libraryOpen) return;
              final pending = browseMenu.show(
                anchor: libraryButtonKey,
                label: '切换媒体库',
                onDirection: (up) {
                  if (mounted && libraryOpen && libraryOpensUp != up) {
                    setState(() => libraryOpensUp = up);
                  }
                },
                maxHeight: 340,
                builder: (select) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BrowseMenuChoice(
                      key: const ValueKey('library-choice-all'),
                      title: '全部',
                      icon: CupertinoIcons.rectangle_stack,
                      selected: parentId == null,
                      onTap: () => select(''),
                    ),
                    for (final library in HomeVisibilityScope.visible(
                      context,
                      widget.api.session!,
                      libraries,
                    ))
                      BrowseMenuChoice(
                        key: ValueKey('library-choice-${library.id}'),
                        title: library.title,
                        icon: switch (library.data['CollectionType']) {
                          'movies' => CupertinoIcons.film,
                          'tvshows' => CupertinoIcons.tv,
                          _ => CupertinoIcons.rectangle_stack,
                        },
                        selected: parentId == library.id,
                        onTap: () => select(library.id),
                      ),
                  ],
                ),
              );
              setState(() => libraryOpen = true);
              final value = await pending;
              if (!mounted) return;
              setState(() => libraryOpen = false);
              if (!mounted || value == null || value == (parentId ?? '')) {
                return;
              }
              setState(() => parentId = value.isEmpty ? null : value);
              await reset();
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '媒体库',
                  style: TextStyle(
                    fontSize: pageHeadingSize(context),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                    color: labelColor(context),
                  ),
                ),
                const SizedBox(width: 8),
                ExpansionChevron(
                  expanded: libraryOpen,
                  opensUp: libraryOpensUp,
                  reducedMotion: widget.reducedMotion,
                  size: 16,
                  color: secondaryColor(context),
                ),
              ],
            ),
          ),
        ),
      ),
      if (parentId != null) ...[
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            libraries.where((item) => item.id == parentId).firstOrNull?.title ??
                '全部',
            key: const Key('library-current-name'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: secondaryColor(context)),
          ),
        ),
      ],
      const SizedBox(width: 8),
    ],
  );
  void changeFilters(
    CatalogFilters value, {
    bool? watched,
    bool changeWatched = false,
  }) {
    dismissSearch();
    debounce?.cancel();
    setState(() {
      filters = value;
      if (changeWatched) played = watched;
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    unawaited(filterCatalog());
  }

  Future<void> selectSort(String value) async {
    dismissSearch();
    final reverse = value != 'alphabet';
    try {
      await widget.browse?.preferences.setSort(value, descending: reverse);
      if (!mounted) return;
      setState(() {
        alphabet = value == 'alphabet';
        sort = alphabet ? '' : value;
        descending = reverse;
      });
      if (scroll.hasClients) scroll.jumpTo(0);
      await filterCatalog();
      if (needsSortMetadata) await buildIndex(refresh: true);
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
    }
  }

  Widget searchFilters() {
    final accessible = HomeVisibilityScope.visible(
      context,
      widget.api.session!,
      indexItems,
    );
    final years = accessible.map(releaseYear).whereType<int>().toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    final decades = years.map((v) => v ~/ 10 * 10).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    CatalogFilters changed({
      CatalogKind? kind,
      int? year,
      int? decade,
      bool dateChanged = false,
    }) => CatalogFilters(
      kind: kind ?? filters.kind,
      year: dateChanged ? year : filters.year,
      decade: dateChanged ? decade : filters.decade,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .45,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilterChips(
              name: 'filter-kind',
              choices: [
                const FilterChoice('all', '全部'),
                for (final library in HomeVisibilityScope.visible(
                  context,
                  widget.api.session!,
                  libraries,
                ))
                  FilterChoice('library:${library.id}', library.title),
                const FilterChoice('favorite', '收藏'),
              ],
              selected: parentId != null
                  ? 'library:$parentId'
                  : filters.kind.name,
              onSelected: (v) async {
                dismissSearch();
                debounce?.cancel();
                final nextParent = v.startsWith('library:')
                    ? v.substring(8)
                    : null;
                final next = changed(
                  kind: v == 'favorite'
                      ? CatalogKind.favorite
                      : CatalogKind.all,
                );
                if (parentId == nextParent) {
                  changeFilters(next);
                } else {
                  setState(() {
                    parentId = nextParent;
                    filters = next;
                  });
                  await reset();
                }
              },
            ),
            FilterChips(
              name: 'filter-sort',
              choices: const [
                FilterChoice('alphabet', '影片名称'),
                FilterChoice('DateCreated', '最新更新'),
                FilterChoice('PremiereDate', '最新上映'),
                FilterChoice('CommunityRating', '影片评分'),
              ],
              selected: alphabet ? 'alphabet' : sort,
              onSelected: selectSort,
            ),
            FilterChips(
              name: 'filter-year',
              choices: [
                const FilterChoice('all', '年份'),
                for (final d in decades) FilterChoice('decade:$d', '$d年代'),
                for (final y in years) FilterChoice('year:$y', '$y'),
              ],
              selected: filters.year != null
                  ? 'year:${filters.year}'
                  : filters.decade != null
                  ? 'decade:${filters.decade}'
                  : 'all',
              onSelected: (v) => changeFilters(
                changed(
                  dateChanged: true,
                  year: v.startsWith('year:')
                      ? int.parse(v.substring(5))
                      : null,
                  decade: v.startsWith('decade:')
                      ? int.parse(v.substring(7))
                      : null,
                ),
              ),
            ),
            FilterChips(
              name: 'filter-watched',
              choices: const [
                FilterChoice('all', '观看状态'),
                FilterChoice('false', '未看'),
                FilterChoice('true', '已看'),
              ],
              selected: played?.toString() ?? 'all',
              onSelected: (v) => changeFilters(
                filters,
                changeWatched: true,
                watched: v == 'all' ? null : v == 'true',
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final resumeVisibleItems = resumeMode
        ? items.where(widget.resumeFeed!.allowsResume).toList()
        : items;
    final unfiltered = catalogMode
        ? catalogShown
        : resumeMode && search.text.trim().isNotEmpty
        ? resumeVisibleItems
              .where((item) => matchesTitle(item, search.text))
              .toList()
        : resumeVisibleItems;
    final visibility = HomeVisibilityScope.of(context);
    final shown =
        visibility?.visible(widget.api.session!, unfiltered) ?? unfiltered;
    final visibleOffsets = !identical(shown, unfiltered)
        ? <String, int>{}
        : letterOffsets;
    if (!identical(visibleOffsets, letterOffsets)) {
      for (var i = 0; i < shown.length; i++) {
        final letter = object(
          shown[i].data[titleKeysField],
        )['letter']?.toString();
        if (letter != null) visibleOffsets.putIfAbsent(letter, () => i);
      }
    }
    final inset = contentInset(context);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final display = resumeMode
        ? LibraryDisplay.standard
        : phoneLayout(context)
        ? LibraryDisplay.posters
        : widget.display;
    return BrowseMenuHost(
      controller: browseMenu,
      enabled:
          widget.active &&
          foreground &&
          (ModalRoute.of(context)?.isCurrent ?? true),
      child: PosterMotionScope(
        active: widget.active && foreground,
        reducedMotion: widget.reducedMotion,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: dismissSearch,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.searchMode)
                SectionHeading(
                  widget.searchMode
                      ? '搜索'
                      : resumeMode
                      ? '继续观看'
                      : widget.parent?.title ?? '媒体库',
                  titleWidget: !resumeMode && widget.parent == null
                      ? libraryPicker()
                      : null,
                ),
              VisibilityStatus(account: widget.api.session!),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  widget.searchMode ? 8 : inset,
                  phoneValue(context, 4, 8),
                  inset,
                  phoneValue(context, 6, 12),
                ),
                child: Row(
                  children: [
                    if (widget.searchMode)
                      IconButton(
                        key: const Key('search-back'),
                        tooltip: '返回首页',
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 44,
                        ),
                        padding: const EdgeInsets.all(10),
                        onPressed: () {
                          dismissSearch();
                          Navigator.maybePop(context);
                        },
                        icon: Icon(
                          CupertinoIcons.arrow_left,
                          size: 24,
                          color: accentColor(context),
                        ),
                      ),
                    Expanded(
                      child: SizedBox(
                        height: 38 * textScale.clamp(1.0, double.infinity),
                        child: Listener(
                          onPointerDown: (_) =>
                              searchFocus.canRequestFocus = true,
                          child: AppGlassSurface(
                            radius: 12,
                            role: GlassRole.control,
                            child: CupertinoSearchTextField(
                              backgroundColor: liquidGlassOf(context)
                                  ? CupertinoColors.transparent
                                  : null,
                              style: phoneLayout(context)
                                  ? TextStyle(
                                      fontSize: 15,
                                      color: labelColor(context),
                                    )
                                  : null,
                              prefixIcon: Icon(
                                CupertinoIcons.search,
                                color: accentColor(context),
                              ),
                              key: const Key('library-search'),
                              focusNode: searchFocus,
                              controller: search,
                              placeholder: resumeMode
                                  ? '搜索名称或拼音'
                                  : alphabet
                                  ? '搜索名称、拼音或演员'
                                  : '搜索影片、剧集或演员',
                              onChanged: (_) {
                                debounce?.cancel();
                                if (catalogMode) {
                                  debounce = Timer(
                                    const Duration(milliseconds: 180),
                                    filterCatalog,
                                  );
                                } else if (resumeMode) {
                                  setState(() {});
                                } else {
                                  debounce = Timer(
                                    const Duration(milliseconds: 500),
                                    reset,
                                  );
                                }
                              },
                              onSubmitted: (_) {
                                debounce?.cancel();
                                if (catalogMode) {
                                  filterCatalog();
                                } else if (resumeMode) {
                                  setState(() {});
                                } else {
                                  reset();
                                }
                              },
                              onSuffixTap: () {
                                search.clear();
                                debounce?.cancel();
                                if (catalogMode) {
                                  filterCatalog();
                                } else if (resumeMode) {
                                  setState(() {});
                                } else {
                                  reset();
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (!resumeMode) ...[
                      const SizedBox(width: 8),
                      Semantics(
                        label: '排序',
                        button: true,
                        child: CupertinoButton(
                          key: sortButtonKey,
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(44, 44),
                          onPressed: sorting,
                          child: CatalogSortIcon(
                            key: const Key('library-sort'),
                            active: played != null,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.searchMode && catalogMode) searchFilters(),
              if (!resumeMode)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    key: const Key('library-status-row'),
                    height: (MediaQuery.textScalerOf(context).scale(12) * 1.4)
                        .clamp(20.0, double.infinity),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          left: inset,
                          right: inset,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              alphabet
                                  ? indexComplete
                                        ? '排序：拼音 ${descending ? 'Z–A' : 'A–Z'} · ${shown.length} 项'
                                        : '拼音 ${descending ? 'Z–A' : 'A–Z'}'
                                  : '排序：${catalogSortLabels[sort] ?? '服务器顺序'} · ${descending ? '降序' : '升序'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.3,
                                color: secondaryColor(context),
                              ),
                            ),
                          ),
                        ),
                        if (busy ||
                            indexing ||
                            filtering ||
                            (widget.refreshFeed?.loading ?? false))
                          const Positioned(
                            top: 0,
                            bottom: 0,
                            right: 3,
                            width: 24,
                            child: Center(
                              child: CupertinoActivityIndicator(
                                key: Key('library-loading-indicator'),
                                radius: 7,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (error != null && shown.isNotEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  child: Text(
                    '更新失败，保留已缓存内容：$error',
                    style: TextStyle(
                      fontSize: 12,
                      color: secondaryColor(context),
                    ),
                  ),
                ),
              Expanded(
                child: shown.isEmpty && !catalogMode && !resumeMode
                    ? MessagePanel(
                        error ?? (busy ? '正在读取媒体库' : '没有找到影视内容'),
                        busy: busy,
                        icon: CupertinoIcons.film,
                        retry: error == null
                            ? null
                            : () {
                                setState(() => error = null);
                                initialized ? load() : initialize();
                              },
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final metrics = LibraryGridMetrics(
                            constraints.maxWidth,
                            textScale,
                            display,
                            phone: phoneLayout(context),
                          );
                          final columns = metrics.columns;
                          final rowHeight = metrics.rowHeight;
                          final spacing = metrics.spacing;
                          const rail = 24.0;
                          visibleItems = shown;
                          gridColumns = columns;
                          gridStride = rowHeight + spacing;
                          syncVisibleLetter();
                          void jump(String letter) {
                            final at = visibleOffsets[letter];
                            if (at == null || !scroll.hasClients) return;
                            visibleLetter.value = letter;
                            final token = ++jumpRevision;
                            scroll.jumpTo(
                              ((at ~/ columns) * (rowHeight + spacing)).clamp(
                                0,
                                scroll.position.maxScrollExtent,
                              ),
                            );
                            // SliverGrid may still estimate its extent from an older
                            // index page. Re-clamp after the target viewport lays out.
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted &&
                                  alphabet &&
                                  scroll.hasClients &&
                                  token == jumpRevision) {
                                scroll.jumpTo(
                                  ((at ~/ columns) * (rowHeight + spacing))
                                      .clamp(
                                        0,
                                        scroll.position.maxScrollExtent,
                                      ),
                                );
                              }
                            });
                          }

                          return Stack(
                            children: [
                              Positioned.fill(
                                child: ScrollToTop(
                                  controller: scroll,
                                  right: metrics.inset + 8,
                                  bottom: DockInset.of(context) > 0
                                      ? DockInset.of(context)
                                      : widget.parent == null &&
                                            !resumeMode &&
                                            !wideLayout(context)
                                      ? browseBottomSpace(context) - 6
                                      : 20,
                                  child: ReleaseRefreshScrollView(
                                    onRefresh: () =>
                                        refreshCurrent(reconcile: true),
                                    busy: widget.refreshFeed?.loading ?? false,
                                    key: PageStorageKey(viewKey),
                                    controller: scroll,
                                    scrollCacheExtent: ScrollCacheExtent.pixels(
                                      rowHeight * 2,
                                    ),
                                    physics: const BouncingScrollPhysics(
                                      parent: AlwaysScrollableScrollPhysics(),
                                    ),
                                    slivers: [
                                      if (!resumeMode)
                                        SliverToBoxAdapter(
                                          child: ActorSearchResults(
                                            api: widget.api,
                                            query: search.text,
                                            active: visible,
                                            onItem: widget.onItem,
                                          ),
                                        ),
                                      if (shown.isEmpty)
                                        SliverToBoxAdapter(
                                          child: Padding(
                                            padding: const EdgeInsets.all(24),
                                            child: Text(
                                              error ??
                                                  (busy || indexing
                                                      ? '正在读取'
                                                      : catalogMode &&
                                                            !indexComplete
                                                      ? '正在读取媒体库'
                                                      : '没有找到影视内容'),
                                            ),
                                          ),
                                        ),
                                      SliverPadding(
                                        padding: EdgeInsets.only(
                                          left: metrics.inset,
                                          right: metrics.rightInset,
                                        ),
                                        sliver: AnchoredSliverGrid(
                                          key: gridKey,
                                          items: shown,
                                          gridDelegate:
                                              SliverGridDelegateWithFixedCrossAxisCount(
                                                crossAxisCount: columns,
                                                mainAxisExtent: rowHeight,
                                                mainAxisSpacing: spacing,
                                                crossAxisSpacing: spacing,
                                              ),
                                          delegate: SliverChildBuilderDelegate(
                                            (context, index) => PosterEntrance(
                                              key: ValueKey(shown[index].id),
                                              id: shown[index].id,
                                              active: widget.active,
                                              child:
                                                  display ==
                                                      LibraryDisplay.posters
                                                  ? LibraryPosterCard(
                                                      item: shown[index],
                                                      api: widget.api,
                                                      active: widget.active,
                                                      onTap: () =>
                                                          choose(shown[index]),
                                                    )
                                                  : MediaCard(
                                                      posterAction: resumeMode
                                                          ? ResumeMenu(
                                                              feed: widget
                                                                  .resumeFeed!,
                                                              item:
                                                                  shown[index],
                                                              onPoster: true,
                                                            )
                                                          : null,
                                                      item: shown[index],
                                                      api: widget.api,
                                                      active: widget.active,
                                                      onTap: () =>
                                                          choose(shown[index]),
                                                      onPlay:
                                                          resumeMode &&
                                                              widget.onPlay !=
                                                                  null
                                                          ? () =>
                                                                widget.onPlay!(
                                                                  shown[index],
                                                                )
                                                          : null,
                                                    ),
                                            ),
                                            childCount: shown.length,
                                          ),
                                        ),
                                      ),
                                      SliverToBoxAdapter(
                                        child: Padding(
                                          padding: EdgeInsets.fromLTRB(
                                            16,
                                            20,
                                            16,
                                            widget.parent == null &&
                                                    !resumeMode &&
                                                    !wideLayout(context)
                                                ? browseBottomSpace(context)
                                                : DockInset.of(context) > 28
                                                ? DockInset.of(context)
                                                : 28,
                                          ),
                                          child: busy
                                              ? const Center(
                                                  child:
                                                      CupertinoActivityIndicator(),
                                                )
                                              : error != null
                                              ? CupertinoButton(
                                                  onPressed: () {
                                                    setState(
                                                      () => error = null,
                                                    );
                                                    catalogMode
                                                        ? refreshCurrent()
                                                        : load();
                                                  },
                                                  child: const Text('重试'),
                                                )
                                              : !catalogMode && more
                                              ? CupertinoButton(
                                                  onPressed: load,
                                                  child: const Text('加载更多'),
                                                )
                                              : Center(
                                                  child: Text(
                                                    catalogMode &&
                                                            !indexComplete
                                                        ? ''
                                                        : '已显示全部',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: secondaryColor(
                                                        context,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (alphabet)
                                Positioned(
                                  top: 0,
                                  bottom: DockInset.of(context) > 0
                                      ? DockInset.of(context)
                                      : phoneLayout(context) &&
                                            widget.parent == null &&
                                            !resumeMode &&
                                            !widget.searchMode
                                      ? browseBottomSpace(context)
                                      : 0,
                                  right: 3,
                                  width: rail,
                                  child: ValueListenableBuilder<String?>(
                                    valueListenable: visibleLetter,
                                    builder: (_, current, _) =>
                                        HorizontalPageSwipeBoundary(
                                          child: AlphabetRail(
                                            descending: descending,
                                            available: visibleOffsets.keys
                                                .toSet(),
                                            current: current,
                                            onSelect: jump,
                                          ),
                                        ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
