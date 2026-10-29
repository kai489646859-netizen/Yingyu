import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'emby.dart';
import 'models.dart';
import 'log.dart';
import 'store.dart';
import 'browse_cache.dart';
import 'resume_visibility.dart';
import 'background_work.dart';
import 'progress.dart';
import 'server_resume.dart';

String resumeTitleKey(MediaItem item) {
  final series = item.data['SeriesId']?.toString() ?? '';
  return (item.type.toLowerCase() == 'episode' && series.trim().isNotEmpty
          ? 'series:$series'
          : 'item:${item.id}')
      .toLowerCase();
}

/// PC 0.6.5 ResumeSeriesMergePolicy: keep the first occurrence of each title
/// in the supplied order. Never substitute one episode's ID or progress.
List<MediaItem> collapseResume(Iterable<MediaItem> entries, {int limit = 18}) {
  final keys = <String>{};
  return entries
      .where((item) => item.id.isNotEmpty && keys.add(resumeTitleKey(item)))
      .take(limit)
      .toList();
}

class HomeSection {
  HomeSection(
    this.library, {
    this.items = const [],
    this.error,
    this.loading = true,
  });
  final MediaItem library;
  List<MediaItem> items;
  String? error;
  bool loading;
}

/// Homepage metadata only. This class never writes playback positions,
/// authenticates a media URL, changes tracks, or prepares a player.
class HomeFeed extends ChangeNotifier {
  HomeFeed(this.api, this.store, {this.browse, this.preloadSearch = false})
    : account = api.session! {
    try {
      final data = object(jsonDecode(store.prefs.getString(cacheKey) ?? '{}'));
      for (final value in objects(data['items'])) {
        final item = MediaItem(object(value['item']));
        final at = DateTime.tryParse(value['observedAt']?.toString() ?? '');
        if (at != null && item.id.isNotEmpty) {
          _recent[item.id] = (item: item, at: at);
          final baseline = value['resumeBaseline'];
          if (value['playbackFingerprint'] == progressFingerprint(item) &&
              (baseline == null ||
                  baseline is String && baseline.length <= 4096)) {
            _playbackReceipts[item.id] = baseline as String?;
          }
          final history = value['historyBaseline'];
          if (history is String &&
              history.length <= 4096 &&
              (value['historyFingerprint'] == progressFingerprint(item) ||
                  value['playbackFingerprint'] == progressFingerprint(item))) {
            _playbackHistory[item.id] = history;
          }
        }
      }
    } catch (_) {
      /* A corrupt optional home cache must not prevent login. */
    }
    _loadVerifiedHistory();
    final cached = _recent.values.toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    // Startup and refresh must apply the same progress/order policy. An old,
    // already-synced local observation must not jump ahead of the last server
    // snapshot (or resurrect an episode that the server has replaced).
    final savedResume = browse?.peek('resume:0:18');
    _loadServerResumeSnapshot();
    if (savedResume != null &&
        (_serverSnapshotAt == null ||
            savedResume.at.isAfter(_serverSnapshotAt!))) {
      _serverResumeRaw = savedResume.items;
      _serverSnapshotAt = savedResume.at;
    }
    _rememberResumeServer(_serverResumeRaw ?? const []);
    // Migrate only durable evidence of actual rewatching, never a generic cache read.
    for (final entry in cached) {
      if (!_playbackReceipts.containsKey(entry.item.id) &&
          entry.item.type == 'Episode' &&
          entry.item.resume > Duration.zero &&
          store.rewatchObserved(account, entry.item)) {
        _playbackReceipts[entry.item.id] =
            _rawResumeObservations['${entry.item.data['SeriesId'] ?? ''}'];
      }
    }
    resume = mergeResume(_serverResumeRaw ?? const []);
    sections = [
      for (final library in browse?.peek('views')?.items ?? <MediaItem>[])
        HomeSection(
          library,
          items: browse?.peek('latest:${library.id}')?.items ?? [],
          loading: false,
        ),
    ];
    store.homeOrder.addListener(changed);
    api.backgroundWork.addListener(_resumeDeferred);
  }
  final EmbyClient api;
  final AppStore store;
  final bool preloadSearch;
  final Session account;
  Iterable<MediaItem> get cachedItems =>
      _recent.values.map((entry) => entry.item);
  late final visibility = ResumeVisibility(store.prefs, account);
  final _removing = <String>{};
  final _removalRevisions = <String, int>{};
  int _resumeMutation = 0;
  int _playbackObservationRevision = 0;
  final _playbackReceipts = <String, String?>{};
  final _playbackHistory = <String, String>{};
  bool removing(MediaItem item) => _removing.contains(resumeTitleKey(item));
  bool allowsResume(MediaItem item) =>
      visibility.allows(item) && store.homeOrder.removals.allows(account, item);

  Future<void> acceptRemovals(Set<String> removed) async {
    if (!current || removed.isEmpty) return;
    _resumeMutation++;
    bool allows(MediaItem item) =>
        store.homeOrder.removals.allows(account, item);
    _recent.removeWhere((_, entry) => !allows(entry.item));
    resume = resume.where(allows).toList();
    sections = sections.where((s) => allows(s.library)).toList();
    for (final section in sections) {
      section.items = section.items.where(allows).toList();
    }
    changed();
    if (!await store.prefs.setString(
      cacheKey,
      jsonEncode({
        'items': [
          for (final entry in _recent.values)
            {
              'observedAt': entry.at.toIso8601String(),
              if (_playbackReceipts.containsKey(entry.item.id))
                'playbackFingerprint': progressFingerprint(entry.item),
              if (_playbackReceipts[entry.item.id] != null)
                'resumeBaseline': _playbackReceipts[entry.item.id],
              if (_playbackHistory.containsKey(entry.item.id))
                'historyBaseline': _playbackHistory[entry.item.id],
              if (_playbackHistory.containsKey(entry.item.id))
                'historyFingerprint': progressFingerprint(entry.item),
              'item': displayMetadata(entry.item.data),
            },
        ],
      }),
    )) {
      throw const AppFailure('首页删除记录保存失败，请重试刷新');
    }
  }

  Future<void> removeFromResume(MediaItem item) async {
    if (!current || paused) throw const AppFailure('当前无法移出继续观看，请返回首页重试');
    final key = resumeTitleKey(item);
    if (!_removing.add(key)) return;
    _removalRevisions[key] = (_removalRevisions[key] ?? 0) + 1;
    _resumeMutation++;
    changed();
    var accepted = false;
    try {
      final data = await _request(
        () => api.hideFromResume(item.id),
        generation,
      );
      accepted = true;
      await visibility.hide(item, data);
    } catch (error) {
      if (accepted) {
        throw AppFailure('Emby 已移出，但本机隐藏记录保存失败：${safeError(error)}');
      }
      rethrow;
    } finally {
      if (accepted) {
        browse?.invalidateResume();
        resume = resume.where(allowsResume).toList();
        lastResumeRefresh = null;
        _resumeMutation++;
      }
      _removing.remove(key);
      changed();
    }
    if (current && !paused) await refreshResume(force: true);
  }

  final BrowseRepository? browse;
  List<HomeSection> sections = [];
  List<HomeSection> get orderedSections =>
      store.homeOrder.apply(account, sections, (s) => s.library.id);
  List<HomeSection> get displaySections {
    final hidden = store.homeOrder.hidden(account);
    return orderedSections
        .where((s) => !hidden.contains(s.library.id))
        .toList();
  }

  List<MediaItem> resume = [];
  String? error, resumeError;
  bool loading = false,
      resumeLoading = false,
      paused = false,
      _disposed = false;
  int generation = 0;
  bool _reloadAfterPause = false;
  DateTime? lastResumeRefresh;
  bool _resumeCheckedThisVisit = false;
  final _recent = <String, ({MediaItem item, DateTime at})>{};
  final _waiting = Queue<Completer<void>>();
  int _requests = 0;
  String get cacheKey =>
      'yingyu.home.v1.${Uri.encodeComponent(account.base.toString())}.${account.userId}';
  bool get current => !_disposed && api.session == account;
  @override
  void dispose() {
    store.homeOrder.removeListener(changed);
    api.backgroundWork.removeListener(_resumeDeferred);
    _disposed = true;
    generation++;
    super.dispose();
  }

  void suspend() {
    _resumeCheckedThisVisit = false;
    _playbackObservationRevision++;
    _reloadAfterPause =
        _reloadAfterPause ||
        loading ||
        resumeLoading ||
        sections.any((section) => section.loading);
    paused = true;
    generation++;
    loading = false;
    resumeLoading = false;
    for (final section in sections) {
      section.loading = false;
    }
  }

  void activate() {
    paused = false;
    _resumeDeferred();
  }

  Future<void>? _deferredJob;
  void _resumeDeferred() {
    if (!current ||
        paused ||
        api.backgroundWork.paused ||
        !_reloadAfterPause ||
        _deferredJob != null) {
      return;
    }
    _deferredJob =
        () async {
          // The cancelled refresh must release its coalesced future first.
          await _refreshJob;
          if (!current || paused || api.backgroundWork.paused) return;
          _reloadAfterPause = false;
          await refresh();
        }().whenComplete(() {
          _deferredJob = null;
          _resumeDeferred();
        });
  }

  bool _deferPaused(Object error, int revision) {
    if (error is! BackgroundPaused) return false;
    if (current && revision == generation) {
      _reloadAfterPause = true;
      _resumeDeferred();
    }
    return true;
  }

  void changed() {
    if (current) notifyListeners();
  }

  Future<T> _request<T>(Future<T> Function() request, int revision) async {
    if (_requests == 2) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _requests++;
    }
    try {
      if (!current || paused || revision != generation) {
        throw const AppFailure('首页请求已取消');
      }
      return await api.backgroundWork.run(request);
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _requests--;
      }
    }
  }

  Future<void>? _refreshJob;
  // Direct metadata reads bypass BrowseRepository's cache, so their exact
  // returned IDs can confirm access without changing any progress projection.
  Future<T> _freshMetadata<T>(
    Future<T> Function() request,
    int revision,
  ) async {
    final policy = store.homeOrder;
    final permissionRevision = policy.serverRevision(account);
    final result = await _request(request, revision);
    if (current && !paused && revision == generation) {
      final Iterable<MediaItem> items = result is MediaItem
          ? <MediaItem>[result]
          : result is List<MediaItem>
          ? result
          : const <MediaItem>[];
      policy.observeServerItems(account, items, revision: permissionRevision);
    }
    return result;
  }

  Future<void>? _forcedRefreshJob;
  bool _refreshForced = false;
  bool _refreshReconcile = false;

  Future<void> refresh({bool force = false, bool reconcile = false}) {
    if (force &&
        _refreshJob != null &&
        (!_refreshForced || reconcile && !_refreshReconcile)) {
      // A cached/automatic read cannot satisfy a later manual server refresh.
      // Queue one forced pass, shared by both pages and repeated gestures.
      return _forcedRefreshJob ??= () async {
        await _refreshJob;
        await refresh(force: true, reconcile: reconcile);
      }().whenComplete(() => _forcedRefreshJob = null);
    }
    if (_refreshJob != null) return _refreshJob!;
    _refreshForced = force;
    _refreshReconcile = reconcile;
    return _refreshJob = _refresh(force: force, reconcile: reconcile)
        .whenComplete(() {
          _refreshJob = null;
          _refreshForced = false;
          _refreshReconcile = false;
        });
  }

  /// Library-wide refresh retains the complete account snapshot; ordinary
  /// homepage refresh only fetches the visible sections and viewing metadata.
  /// Failures remain visible on the page that initiated the operation.
  Future<void> refreshAll() async {
    if (!current || paused || api.backgroundWork.paused) {
      throw const BackgroundPaused();
    }
    await refresh(force: true, reconcile: true);
    if (!current || paused || api.backgroundWork.paused || _reloadAfterPause) {
      throw const BackgroundPaused();
    }
    final failures = [
      ?error,
      if (resumeError != null) '继续观看：$resumeError',
      for (final section in sections)
        if (section.error != null) '${section.library.title}：${section.error}',
    ];
    if (failures.isNotEmpty) throw AppFailure(failures.join('\n'));
  }

  /// A user retry waits for an older refresh, then bypasses stale metadata once.
  Future<void> retry() async {
    await _refreshJob;
    if (current && !paused) await refresh(force: true);
  }

  Future<void> _refresh({bool force = false, bool reconcile = false}) async {
    if (!current || paused || loading) return;
    final elapsed = Stopwatch()..start();
    final stages = <String, int>{};
    var stageStart = 0;
    void finishStage(String name) {
      final at = elapsed.elapsedMilliseconds;
      stages[name] = at - stageStart;
      stageStart = at;
    }

    if (force) browse?.cancelSearchWarmup();
    final revision = ++generation;
    loading = true;
    error = null;
    final confirmed = browse?.beginConfirmation();
    browse?.cache.beginBatch();
    changed();
    try {
      final libraries = await _request(
        () => browse?.libraries(force: force) ?? api.libraries(),
        revision,
      );
      if (!current || paused || revision != generation) return;
      final previous = {
        for (final section in sections) section.library.id: section,
      };
      sections = libraries
          .where((library) => library.id.isNotEmpty)
          .map(
            (library) =>
                HomeSection(library, items: previous[library.id]?.items ?? []),
          )
          .toList();
      changed();
      // Same two-request ceiling as PC's homepage, including the resume list.
      final jobs = <Future<void> Function()>[
        () => refreshResume(
          force: true,
          useCache: !force && _resumeCheckedThisVisit,
        ),
        for (final section in sections)
          () => loadSection(section, revision, force: force),
      ];
      var next = 0;
      Future<void> worker() async {
        while (current &&
            !paused &&
            revision == generation &&
            next < jobs.length) {
          final job = jobs[next++];
          await job();
        }
      }

      await Future.wait([worker(), worker()]);
      finishStage('首页资料');
      if (current && !paused && revision == generation) {
        if (force && reconcile && browse != null) {
          await browse!.catalogue(force: true, resourceSnapshot: true);
        } else {
          await browse?.ensureVisibility();
        }
        finishStage('目录核对');
      }
      if (force &&
          reconcile &&
          current &&
          !paused &&
          revision == generation &&
          browse != null) {
        final missing = await browse!.finishLocalSync();
        if (!current || paused || revision != generation) return;
        if (missing.isNotEmpty) {
          _recent.removeWhere((id, _) => missing.contains(id));
          resume.removeWhere((item) => missing.contains(item.id));
          for (final section in sections) {
            section.items = section.items
                .where((item) => !missing.contains(item.id))
                .toList();
          }
          if (!await store.prefs.setString(
            cacheKey,
            jsonEncode({
              'items': [
                for (final entry in _recent.values)
                  {
                    'observedAt': entry.at.toIso8601String(),
                    if (_playbackReceipts.containsKey(entry.item.id))
                      'playbackFingerprint': progressFingerprint(entry.item),
                    if (_playbackReceipts[entry.item.id] != null)
                      'resumeBaseline': _playbackReceipts[entry.item.id],
                    if (_playbackHistory.containsKey(entry.item.id))
                      'historyBaseline': _playbackHistory[entry.item.id],
                    if (_playbackHistory.containsKey(entry.item.id))
                      'historyFingerprint': progressFingerprint(entry.item),
                    'item': displayMetadata(entry.item.data),
                  },
              ],
            }),
          )) {
            throw const AppFailure('过期首页缓存清理保存失败，请重试');
          }
        }
        finishStage('本机清理');
      }
    } catch (e) {
      if (!_deferPaused(e, revision) && current && revision == generation) {
        error = safeError(e);
      }
    } finally {
      if (confirmed != null) browse?.endConfirmation(confirmed);
      try {
        finishStage('其他处理');
        await browse?.cache.endBatch();
        finishStage('缓存落盘');
      } catch (e) {
        if (current && revision == generation) error = safeError(e);
      }
      if (current && revision == generation) {
        loading = false;
        // Invalidate mounted and saved browse views after a successful manual
        // homepage read. Each page reloads its own scope when it becomes visible;
        // the homepage still performs no full inventory scan.
        if (force &&
            error == null &&
            resumeError == null &&
            sections.every((section) => section.error == null)) {
          browse?.markViewsStale();
        }
        store.log.add(
          LogArea.app,
          '首页${force ? '手动' : '自动'}刷新完成：总耗时=${elapsed.elapsedMilliseconds} ms；分区=${sections.length}；'
          '方式=${force
              ? reconcile
                    ? '完整目录核对'
                    : '首页资料核对'
              : '按需复用缓存'}；'
          '${stages.entries.map((e) => '${e.key}=${e.value} ms').join('；')}；'
          '结果=${error == null && resumeError == null && sections.every((s) => s.error == null) ? '完成' : '有错误，原记录保留'}',
        );
        changed();
        if (!force &&
            preloadSearch &&
            sections.isNotEmpty &&
            error == null &&
            resumeError == null &&
            sections.every((s) => s.error == null) &&
            !(browse?.visibility?.filtering(account) ?? false)) {
          unawaited(browse?.warmSearchCatalogue());
        }
      }
    }
  }

  Future<void> loadSection(
    HomeSection section,
    int revision, {
    bool force = false,
  }) async {
    if (!current || paused || revision != generation) return;
    section.loading = true;
    section.error = null;
    changed();
    try {
      final values = await _request(
        () =>
            browse?.latest(section.library.id, force: force) ??
            api.latestItems(section.library.id),
        revision,
      );
      if (!current || paused || revision != generation) return;
      section.items = values.where((item) => item.id.isNotEmpty).toList();
    } catch (e) {
      if (!_deferPaused(e, revision) && current && revision == generation) {
        section.error = safeError(e);
      }
    } finally {
      if (current && revision == generation) {
        section.loading = false;
        changed();
      }
    }
  }

  Future<void> refreshResume({
    bool force = false,
    bool useCache = false,
  }) async {
    if (!current ||
        paused ||
        resumeLoading ||
        (!force &&
            lastResumeRefresh != null &&
            DateTime.now().difference(lastResumeRefresh!) <
                const Duration(minutes: 1))) {
      return;
    }
    final revision = generation;
    resumeLoading = true;
    final mutation = _resumeMutation;
    resumeError = null;
    changed();
    try {
      final page = await _request(
        () => browse?.resume(force: force && !useCache) ?? api.resumeItems(),
        revision,
      );
      if (!current || paused || revision != generation) return;
      if (mutation != _resumeMutation) return;
      if (force && !useCache) await visibility.observeServer(page.items);
      if (!current ||
          paused ||
          revision != generation ||
          mutation != _resumeMutation) {
        return;
      }
      _rememberResumeServer(page.items);
      _serverResumeRaw = List<MediaItem>.of(page.items.take(18));
      if (browse == null || force && !useCache) {
        _resumeCheckedThisVisit = true;
        _serverSnapshotAt = DateTime.now();
        await _saveServerResumeSnapshot(revision, mutation);
      }
      if (!current ||
          paused ||
          revision != generation ||
          mutation != _resumeMutation) {
        return;
      }
      final projection = mergeResume(page.items);
      final firstRaw = page.items.firstOrNull;
      final firstType = const {'Episode', 'Movie'}.contains(firstRaw?.type)
          ? firstRaw!.type
          : 'other';
      final sourceIndices = projection
          .take(4)
          .map((row) => page.items.indexWhere((raw) => raw.id == row.id))
          .join(',');
      final extraLocalRows = projection
          .where((row) => !page.items.any((raw) => raw.id == row.id))
          .length;
      store.log.add(
        LogArea.app,
        '[HOME175] 继续观看服务器投影：原始=${page.items.length}；显示=${projection.length}；额外本机卡片=$extraLocalRows；显示前项源序号=$sourceIndices；原始首项类型=$firstType；季=${integer(firstRaw?.data['ParentIndexNumber'])}；集=${integer(firstRaw?.data['IndexNumber'])}；位置=${firstRaw?.resume.inMilliseconds ?? 0} ms；未写观看进度',
      );
      if (store.homeOrder.serverHandlesHidden(account)) {
        final pending = projection
            .where(
              (item) =>
                  store.homeOrder.needsServerConfirmation(account, [item]),
            )
            .map((item) => item.id);
        for (final batch in itemLookupBatches(pending)) {
          await _freshMetadata(() => api.progressItems(batch), revision);
          if (!current ||
              paused ||
              revision != generation ||
              mutation != _resumeMutation) {
            return;
          }
        }
      }
      resume = projection;
      lastResumeRefresh = DateTime.now();
    } catch (e) {
      if (!_deferPaused(e, revision) &&
          current &&
          revision == generation &&
          mutation == _resumeMutation) {
        resumeError = safeError(e);
      }
    } finally {
      if (current && revision == generation) {
        resumeLoading = false;
        changed();
      }
    }
  }

  final _detailHistory = <String, MediaItem>{};
  final _detailResumeBaseline = <String, String>{};
  // Preserve the rejected source observation separately from the selected card.
  // Opening details can select the new Resume row; that must not make an old,
  // undated DatePlayed result look newly observed after process recreation.
  final _supersededHistory = <String, String>{};
  String get verifiedHistoryKey => '$cacheKey.verified.v1';
  void _loadVerifiedHistory() {
    try {
      final raw = store.prefs.getString(verifiedHistoryKey);
      if (raw == null || raw.length > 512 * 1024) return;
      final saved = object(jsonDecode(raw));
      if (saved['version'] != 1) return;
      for (final entry in object(saved['supersededHistory']).entries.take(96)) {
        final checkpoint = entry.value;
        if (entry.key.isNotEmpty &&
            checkpoint is String &&
            checkpoint.length <= 4096) {
          _supersededHistory[entry.key] = checkpoint;
        }
      }
      for (final row in objects(saved['items']).take(96)) {
        final item = MediaItem(object(row['item']));
        final series = item.data['SeriesId']?.toString() ?? '';
        final baseline = row['baseline'];
        if (item.type != 'Episode' ||
            item.id.isEmpty ||
            series.isEmpty ||
            baseline is! String ||
            baseline.length > 4096) {
          continue;
        }
        _detailHistory[series] = item;
        _detailResumeBaseline[series] = baseline;
      }
    } catch (_) {
      // Optional display corrections never replace durable playback progress.
    }
  }

  Future<void> _verifiedWrite = Future.value();
  Future<void> _saveVerifiedHistory() {
    final job = _verifiedWrite.then((_) async {
      if (!current) return;
      const fields = {
        'Id',
        'Name',
        'Type',
        'SeriesId',
        'SeriesName',
        'SeasonId',
        'IndexNumber',
        'ParentIndexNumber',
        'UserData',
        'RunTimeTicks',
        'ImageTags',
        'SeriesPrimaryImageTag',
        'ParentThumbItemId',
        'ParentThumbImageTag',
      };
      final text = jsonEncode({
        'version': 1,
        'supersededHistory': _supersededHistory,
        'items': [
          for (final entry in _detailHistory.entries)
            if (_detailResumeBaseline.containsKey(entry.key))
              {
                'item': {
                  for (final field in displayMetadata(entry.value.data).entries)
                    if (fields.contains(field.key)) field.key: field.value,
                },
                'baseline': _detailResumeBaseline[entry.key],
              },
        ],
      });
      if (text.length > 512 * 1024 ||
          !await store.prefs.setString(verifiedHistoryKey, text)) {
        throw const AppFailure('首页显示核对缓存未保存');
      }
    });
    _verifiedWrite = job.catchError((Object _) {});
    return job;
  }

  List<MediaItem>? _serverResumeRaw;
  DateTime? _serverSnapshotAt;
  Future<void> _serverSnapshotWrite = Future.value();
  String get serverResumeKey => '$cacheKey.server.v1';
  void _loadServerResumeSnapshot() {
    try {
      final text = store.prefs.getString(serverResumeKey);
      if (text == null || text.length > 512 * 1024) return;
      final value = object(jsonDecode(text));
      final at = DateTime.tryParse('${value['at']}');
      if (value['version'] != 1 ||
          value['items'] is! List ||
          (value['items'] as List).length > 18 ||
          at == null) {
        return;
      }
      _serverResumeRaw = objects(value['items']).map(MediaItem.new).toList();
      _serverSnapshotAt = at;
    } catch (_) {
      // A corrupt optional snapshot is not local viewing evidence.
    }
  }

  Future<void> _saveServerResumeSnapshot(int revision, int mutation) {
    final text = jsonEncode({
      'version': 1,
      'at': _serverSnapshotAt!.toIso8601String(),
      'items': [
        for (final item in _serverResumeRaw!) displayMetadata(item.data),
      ],
    });
    final job = _serverSnapshotWrite.then((_) async {
      if (!current ||
          paused ||
          revision != generation ||
          mutation != _resumeMutation) {
        return;
      }
      try {
        if (text.length > 512 * 1024 ||
            !await store.prefs.setString(serverResumeKey, text)) {
          throw const AppFailure('服务器继续观看快照未保存');
        }
      } catch (_) {
        store.log.add(
          LogArea.app,
          '服务器继续观看快照未保存；本次实时显示仍保留',
          level: LogLevel.warning,
        );
      }
    });
    _serverSnapshotWrite = job;
    return job;
  }

  final _rawResumeObservations = <String, String>{};
  void _rememberResumeServer(Iterable<MediaItem> items) {
    _rawResumeObservations.clear();
    for (final item in items) {
      if (item.type == 'Episode') {
        final series = item.data['SeriesId']?.toString() ?? '';
        if (series.isNotEmpty) {
          _rawResumeObservations.putIfAbsent(
            series,
            () => _resumeObservation(item),
          );
        }
      }
    }
  }

  static String _resumeObservation(MediaItem item) => jsonEncode([
    item.id,
    progressFingerprint(item),
    item.duration.inMilliseconds,
  ]);

  // Older releases included duration in this serialized observation. A list
  // may omit or refine RunTimeTicks without changing the viewing checkpoint;
  // that metadata difference must not invalidate a confirmed local episode.
  // Continue accepting the existing format so installed receipts survive.
  static bool _sameResumeCheckpoint(String? observation, MediaItem item) {
    if (observation == null) return false;
    try {
      final value = jsonDecode(observation);
      if (value is! List || value.length != 3 || value[0] != item.id) {
        return false;
      }
      if (value[1] == progressFingerprint(item)) return true;
      final user = object(item.data['UserData']);
      // A later sparse list can omit or lose a previously valid optional date.
      // This one-way loss to an unknown value is not a new watch. Never ignore
      // a supplied valid date, changed position/Played/PlayCount, or new date.
      final suppliedDate = (user['LastPlayedDate']?.toString() ?? '').trim();
      if (DateTime.tryParse(suppliedDate) != null || value[1] is! String) {
        return false;
      }
      final previous = jsonDecode(value[1] as String);
      return previous is List &&
          previous.length == 4 &&
          previous[1] is String &&
          DateTime.tryParse(previous[1] as String) != null &&
          previous[0] == item.resume.inMilliseconds &&
          previous[2] == user['Played'] &&
          previous[3] == user['PlayCount'];
    } catch (_) {
      return false;
    }
  }

  // A verified detail read can be newer than the Resume endpoint. Keep that
  // one episode's own identity/position together, until a newer server date or
  // a changed checkpoint (including a backwards seek) supersedes it.
  bool _historyReplaced(
    ({MediaItem item, DateTime at}) observation,
    MediaItem? verified,
  ) {
    final recent = observation.item,
        series = '${observation.item.data['SeriesId'] ?? ''}';
    final verifiedAt = DateTime.tryParse(
      '${object(verified?.data['UserData'])['LastPlayedDate']}',
    );
    return recent.type == 'Episode' &&
        series.isNotEmpty &&
        verified != null &&
        verified.type == 'Episode' &&
        '${verified.data['SeriesId'] ?? ''}' == series &&
        verified.id != recent.id &&
        (verifiedAt == null || !verifiedAt.isBefore(observation.at)) &&
        store.localProgress(account, recent.id) == null &&
        DateTime.now().difference(observation.at) >=
            const Duration(seconds: 30) &&
        !_sameResumeCheckpoint(_supersededHistory[series], verified) &&
        !_sameResumeCheckpoint(_playbackHistory[recent.id], verified);
  }

  MediaItem? recentEpisode(String seriesId) {
    if (!current) return null;
    final server = _serverResumeRaw
        ?.where(
          (item) => item.type == 'Episode' && item.data['SeriesId'] == seriesId,
        )
        .firstOrNull;
    if (_serverResumeRaw != null) {
      return server == null ? null : ServerResumeItem(server);
    }
    final verified = _detailHistory[seriesId];
    final recent =
        _recent.values
            .where(
              (value) =>
                  value.item.type == 'Episode' &&
                  value.item.data['SeriesId'] == seriesId &&
                  !_historyReplaced(value, verified),
            )
            .toList()
          ..sort((a, b) => b.at.compareTo(a.at));
    final candidates = <({MediaItem item, DateTime at})>[
      ...recent,
      for (final item in [
        if (verified != null &&
            !_sameResumeCheckpoint(_supersededHistory[seriesId], verified))
          verified,
        store.completions.latest(account, seriesId),
      ])
        if (item != null)
          if (!_historyReplaced((
            item: item,
            at:
                DateTime.tryParse(
                  '${object(item.data['UserData'])['LastPlayedDate']}',
                ) ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ), verified))
            (
              item: item,
              at:
                  DateTime.tryParse(
                    '${object(item.data['UserData'])['LastPlayedDate']}',
                  ) ??
                  DateTime.fromMillisecondsSinceEpoch(0),
            ),
    ]..sort((a, b) => b.at.compareTo(a.at));
    return candidates.firstOrNull?.item ??
        resume
            .where(
              (entry) =>
                  entry.type == 'Episode' && entry.data['SeriesId'] == seriesId,
            )
            .firstOrNull;
  }

  Future<MediaItem?> lastWatchedEpisode(String seriesId) async {
    final before = resume
        .where(
          (item) => item.type == 'Episode' && item.data['SeriesId'] == seriesId,
        )
        .firstOrNull;
    final previous = _detailHistory[seriesId];
    final previousBaseline = _detailResumeBaseline[seriesId];
    // Reopening details must not replace the raw server baseline with our own
    // projected card, otherwise the same stale response would look new later.
    final baseline =
        _rawResumeObservations[seriesId] ??
        (before == null
            ? null
            : previous != null &&
                  previousBaseline != null &&
                  _resumeObservation(before) == _resumeObservation(previous)
            ? previousBaseline
            : _resumeObservation(before));
    final latest = await _freshMetadata(
      () => api.lastWatchedEpisode(seriesId),
      generation,
    );
    if (!current) return null;
    if (latest != null && _serverResumeRaw != null) {
      _detailHistory[seriesId] = latest;
      if (baseline != null) _detailResumeBaseline[seriesId] = baseline;
      while (_detailHistory.length > 96) {
        final oldest = _detailHistory.keys.first;
        _detailHistory.remove(oldest);
        _detailResumeBaseline.remove(oldest);
      }
      try {
        await _saveVerifiedHistory();
      } catch (_) {
        store.log.add(LogArea.app, '最近观看显示缓存未保存；服务器读取结果保留');
      }
      return current ? latest : null;
    }
    final local =
        _recent.values
            .where(
              (value) =>
                  value.item.type == 'Episode' &&
                  value.item.data['SeriesId'] == seriesId &&
                  !_historyReplaced(value, latest),
            )
            .toList()
          ..sort((a, b) => b.at.compareTo(a.at));
    // Detail focus follows the last actual viewing, including a partial
    // episode. The observation time belongs to that local playback; an
    // embedded LastPlayedDate may still describe an older server checkpoint.
    // This is display metadata only, not the resume-position merge policy.
    var selected = latest;
    var selectedAt = DateTime.tryParse(
      object(latest?.data['UserData'])['LastPlayedDate']?.toString() ?? '',
    );
    final shown = resume
        .where(
          (item) => item.type == 'Episode' && item.data['SeriesId'] == seriesId,
        )
        .firstOrNull;
    final shownAt = DateTime.tryParse(
      object(shown?.data['UserData'])['LastPlayedDate']?.toString() ?? '',
    );
    if (latest != null &&
        _sameResumeCheckpoint(_supersededHistory[seriesId], latest)) {
      selected =
          shown ??
          (previous != null &&
                  !_sameResumeCheckpoint(_supersededHistory[seriesId], previous)
              ? previous
              : null);
      selectedAt = DateTime.tryParse(
        object(selected?.data['UserData'])['LastPlayedDate']?.toString() ?? '',
      );
    }
    final unchangedHistory =
        previous != null &&
        latest != null &&
        _sameResumeCheckpoint(_resumeObservation(previous), latest);
    final changedResume =
        shown != null &&
        previousBaseline != null &&
        !_sameResumeCheckpoint(previousBaseline, shown);
    if (shown != null &&
        ((shownAt != null &&
                (selectedAt == null || shownAt.isAfter(selectedAt))) ||
            (unchangedHistory &&
                changedResume &&
                (shownAt == null ||
                    selectedAt == null ||
                    !shownAt.isBefore(selectedAt))))) {
      selected = shown;
      selectedAt = shownAt;
    }
    final completed = store.completions.latest(account, seriesId);
    final completedAt = DateTime.tryParse(
      '${object(completed?.data['UserData'])['LastPlayedDate']}',
    );
    if (completed != null &&
        completedAt != null &&
        !_historyReplaced((
          item: completed,
          at: completedAt,
        ), latest ?? selected) &&
        (selectedAt == null || completedAt.isAfter(selectedAt))) {
      selected = completed;
      selectedAt = completedAt;
    }
    final observation = local.firstOrNull;
    if (observation != null &&
        (selectedAt == null || observation.at.isAfter(selectedAt))) {
      // For the same episode keep the freshest server fields/progress.
      selected = latest?.id == observation.item.id ? latest : observation.item;
    }
    if (selected != null) {
      _detailHistory[seriesId] = selected;
      if (baseline != null) _detailResumeBaseline[seriesId] = baseline;
      if (_detailHistory.length > 96) {
        final oldest = _detailHistory.keys.first;
        _detailHistory.remove(oldest);
        _detailResumeBaseline.remove(oldest);
      }
      if (before != null) {
        resume = mergeResume(resume);
        changed();
      }
      try {
        await _saveVerifiedHistory();
      } catch (_) {
        store.log.add(
          LogArea.app,
          '首页显示核对缓存未保存；本次显示保留，下次启动需重新核对',
          level: LogLevel.warning,
        );
      }
    }
    return selected;
  }

  /// Preserve server order and the first server row of each title. Local
  /// pending/EOF/history records are synchronization state, not extra cards.
  List<MediaItem> mergeResume(Iterable<MediaItem> entries, {int limit = 18}) =>
      collapseResume(
        entries.where(allowsResume),
        limit: limit,
      ).map(ServerResumeItem.new).toList();

  static MediaItem withPosition(MediaItem item, Duration position) =>
      MediaItem({
        ...item.data,
        'UserData': {
          ...object(item.data['UserData']),
          'PlaybackPositionTicks': ticks(position),
        },
      });

  /// Called after the existing player has closed and finished its own sync.
  Future<void> acceptWatchedState(MediaItem saved) async {
    if (!current) return;
    _resumeMutation++;
    _recent.remove(saved.id);
    _playbackReceipts.remove(saved.id);
    _playbackHistory.remove(saved.id);
    resume.removeWhere((item) => item.id == saved.id);
    browse?.invalidateProgress(saved.id);
    browse?.invalidateResume();
    if (!await store.prefs.setString(
      cacheKey,
      jsonEncode({
        'items': [
          for (final value in _recent.values)
            {
              'observedAt': value.at.toIso8601String(),
              if (_playbackReceipts.containsKey(value.item.id))
                'playbackFingerprint': progressFingerprint(value.item),
              if (_playbackReceipts[value.item.id] != null)
                'resumeBaseline': _playbackReceipts[value.item.id],
              if (_playbackHistory.containsKey(value.item.id))
                'historyBaseline': _playbackHistory[value.item.id],
              if (_playbackHistory.containsKey(value.item.id))
                'historyFingerprint': progressFingerprint(value.item),
              'item': displayMetadata(value.item.data),
            },
        ],
      }),
    )) {
      throw const AppFailure('Emby 已更新，但首页记录保存失败，请重试');
    }
    changed();
    if (!paused) await refreshResume(force: true);
  }

  /// Called after the existing player has closed and finished its own sync.
  /// Only metadata for this new row is cached; old progress storage is untouched.
  Future<void> afterPlayback(
    MediaItem original, {
    bool? actualCompleted,
  }) async {
    if (!current || paused || removing(original)) return;
    final watchedAt = DateTime.now();
    final observationRevision = ++_playbackObservationRevision;
    _resumeMutation++;
    browse?.invalidateProgress(original.id);
    final revision = generation;
    final removalKey = resumeTitleKey(original);
    final removal = _removalRevisions[removalKey];
    final displayBefore = store.watchDisplaySnapshot(account, original.id);
    var detail = original;
    try {
      detail = await _freshMetadata(() => api.detail(original.id), revision);
    } catch (_) {
      /* The existing sync warning remains visible to the user. */
    }
    if (!current ||
        paused ||
        observationRevision != _playbackObservationRevision) {
      return;
    }
    if (removal != _removalRevisions[removalKey]) return;
    try {
      await visibility.played(original);
    } catch (error) {
      resumeError = safeError(error);
      changed();
    }
    if (!current ||
        paused ||
        observationRevision != _playbackObservationRevision ||
        removal != _removalRevisions[removalKey]) {
      return;
    }
    final local = store.localProgress(account, original.id);
    final position = store.resume(account, detail).position;
    final restart = store.restartObserved(account, detail);
    final completed =
        store.completions.completed(account, detail) &&
        (!store.completions.superseded(account, detail.id) ||
            object(detail.data['UserData'])['Played'] == true) &&
        (local == null || local == Duration.zero) &&
        !restart &&
        (actualCompleted == true ||
            (position == Duration.zero && actualCompleted != false));
    final observed = completed
        ? MediaItem({
            ...detail.data,
            'UserData': {
              ...object(detail.data['UserData']),
              'Played': true,
              'PlaybackPositionTicks': 0,
            },
          })
        : withPosition(detail, position);
    _recent.remove(original.id);
    _playbackReceipts.remove(original.id);
    _playbackHistory.remove(original.id);
    if (actualCompleted == false &&
        observed.type == 'Episode' &&
        observed.resume > Duration.zero) {
      _playbackReceipts[original.id] =
          _rawResumeObservations['${observed.data['SeriesId'] ?? ''}'];
    }
    if (observed.type == 'Episode') {
      final series = '${observed.data['SeriesId'] ?? ''}';
      final history = _detailHistory[series];
      final baseline = history == null
          ? _rawResumeObservations[series]
          : _resumeObservation(history);
      if (baseline != null) _playbackHistory[original.id] = baseline;
    }
    // Keep the actual server observation for a pending restart. Only the
    // visible row projects it to the local checkpoint; changing its stored
    // fingerprint would lose a still-unsynced zero during the next refresh.
    _recent[original.id] = (item: restart ? detail : observed, at: watchedAt);
    resume = mergeResume(_serverResumeRaw ?? const []);
    while (_recent.length > 18) {
      final oldest = _recent.keys.first;
      _recent.remove(oldest);
      _playbackReceipts.remove(oldest);
      _playbackHistory.remove(oldest);
    }
    changed();
    store.log.add(
      LogArea.app,
      '[HOME152] 实际观看返回已接收：分集=${observed.type == 'Episode' ? '是' : '否'}；位置=${position.inMilliseconds} ms；本机回执=${_playbackReceipts.containsKey(original.id) ? '已保留' : '不适用'}；不依赖首页手动刷新',
    );
    const metadata = {
      'Id',
      'Name',
      'Type',
      'MediaType',
      'SeriesId',
      'SeriesName',
      'SeasonId',
      'IndexNumber',
      'ParentIndexNumber',
      'UserData',
      'RunTimeTicks',
      'ProviderIds',
      'ImageTags',
      'BackdropImageTags',
      'ParentBackdropItemId',
      'ParentBackdropImageTags',
      'ParentThumbItemId',
      'ParentThumbImageTag',
      'SeriesPrimaryImageTag',
    };
    try {
      if (actualCompleted != null) {
        await store.recordWatchDisplay(
          account,
          detail,
          position,
          !completed &&
              (restart ||
                  (position > Duration.zero &&
                      object(detail.data['UserData'])['Played'] == true)),
          restart: restart,
          expected: displayBefore,
          allowed: () =>
              current &&
              !paused &&
              observationRevision == _playbackObservationRevision &&
              removal == _removalRevisions[removalKey],
        );
      }
      final saved = await store.prefs.setString(
        cacheKey,
        jsonEncode({
          'items': [
            for (final value in _recent.values)
              {
                'observedAt': value.at.toIso8601String(),
                if (_playbackReceipts.containsKey(value.item.id))
                  'playbackFingerprint': progressFingerprint(value.item),
                if (_playbackReceipts[value.item.id] != null)
                  'resumeBaseline': _playbackReceipts[value.item.id],
                if (_playbackHistory.containsKey(value.item.id))
                  'historyBaseline': _playbackHistory[value.item.id],
                if (_playbackHistory.containsKey(value.item.id))
                  'historyFingerprint': progressFingerprint(value.item),
                'item': {
                  for (final entry in value.item.data.entries)
                    if (metadata.contains(entry.key)) entry.key: entry.value,
                },
              },
          ],
        }),
      );
      if (!saved && current) {
        resumeError = '继续观看本机记录保存失败';
        changed();
      }
    } catch (_) {
      if (current) {
        resumeError = '继续观看本机记录保存失败';
        changed();
      }
    }
    if (!paused) await refreshResume(force: true);
  }
}
