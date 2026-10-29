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
    _rememberResumeServer(savedResume?.items ?? const []);
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
    resume = mergeResume(
      savedResume?.items ??
          [
            for (final entry in cached)
              if (store.resume(account, entry.item).position > Duration.zero)
                withPosition(
                  entry.item,
                  store.resume(account, entry.item).position,
                ),
          ],
    );
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
        () => refreshResume(force: true, useCache: !force),
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
      var retiredReceipt = false;
      final retiredIds = <String>{};
      for (final entry in _recent.values) {
        if (!_playbackReceipts.containsKey(entry.item.id)) continue;
        if (_playbackReceipts[entry.item.id] == '!superseded' &&
            store.localProgress(account, entry.item.id) == null) {
          retiredIds.add(entry.item.id);
          retiredReceipt = true;
          continue;
        }
        final remote = page.items
            .where(
              (item) =>
                  item.type == 'Episode' &&
                  item.id != entry.item.id &&
                  item.data['SeriesId'] == entry.item.data['SeriesId'],
            )
            .firstOrNull;
        if (remote == null) continue;
        final remoteAt = DateTime.tryParse(
          '${object(remote.data['UserData'])['LastPlayedDate']}',
        );
        if (_playbackReceipts[entry.item.id] != '!superseded' &&
            (!_sameResumeCheckpoint(_playbackReceipts[entry.item.id], remote) ||
                remoteAt != null && remoteAt.isAfter(entry.at))) {
          _playbackReceipts[entry.item.id] = '!superseded';
          if (store.localProgress(account, entry.item.id) == null) {
            retiredIds.add(entry.item.id);
          }
          retiredReceipt = true;
        }
      }
      for (final id in retiredIds) {
        _recent.remove(id);
        _playbackReceipts.remove(id);
      }
      if (retiredReceipt) {
        await store.prefs.setString(
          cacheKey,
          jsonEncode({
            'items': [
              for (final entry in _recent.values)
                {
                  'observedAt': entry.at.toIso8601String(),
                  'item': displayMetadata(entry.item.data),
                  if (_playbackReceipts.containsKey(entry.item.id))
                    'playbackFingerprint': progressFingerprint(entry.item),
                  if (_playbackReceipts[entry.item.id] != null)
                    'resumeBaseline': _playbackReceipts[entry.item.id],
                },
            ],
          }),
        );
      }
      if (!current ||
          paused ||
          revision != generation ||
          mutation != _resumeMutation) {
        return;
      }
      _rememberResumeServer(page.items);
      await _reconcileResumeHistory(
        page.items,
        revision: revision,
        mutation: mutation,
        force: force && !useCache,
      );
      if (!current ||
          paused ||
          revision != generation ||
          mutation != _resumeMutation) {
        return;
      }
      resume = mergeResume(page.items);
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

  /// Account-scoped metadata fallback for every series detail entry point.
  DateTime? _historyRefreshed;
  String? _historyInput;
  Future<void> _reconcileResumeHistory(
    List<MediaItem> items, {
    required int revision,
    required int mutation,
    required bool force,
  }) async {
    final series = <String, MediaItem>{};
    for (final item in items) {
      final id = '${item.data['SeriesId'] ?? ''}';
      if (item.type == 'Episode' && id.isNotEmpty) {
        series.putIfAbsent(id, () => item);
      }
    }
    if (series.isEmpty) return;
    final input = jsonEncode(series.values.map(_resumeObservation).toList());
    if (!force &&
        _historyInput == input &&
        _historyRefreshed != null &&
        DateTime.now().difference(_historyRefreshed!) <
            const Duration(minutes: 1)) {
      return;
    }
    final before = Map<String, MediaItem>.of(_detailHistory);
    final baselines = Map<String, String>.of(_detailResumeBaseline);
    List<MediaItem> latest;
    try {
      latest = await _request(api.recentWatchedEpisodes, revision);
    } catch (error) {
      if (error is BackgroundPaused) rethrow;
      if (current && !paused && revision == generation) {
        store.log.add(LogArea.app, '首页最近观看批量核对未完成；保留已有核对记录，不写播放进度');
      }
      return;
    }
    if (!current ||
        paused ||
        revision != generation ||
        mutation != _resumeMutation) {
      return;
    }
    final seen = <String>{};
    var matchedHistory = 0;
    var changedHistory = false;
    var missingDate = 0;
    var olderDate = 0;
    var changedCheckpoint = 0;
    var supersededHistory = 0;
    for (final candidate in latest) {
      final id = '${candidate.data['SeriesId'] ?? ''}';
      final server = series[id];
      if (!seen.add(id) ||
          server == null ||
          !allowsResume(candidate) ||
          !identical(before[id], _detailHistory[id]) ||
          baselines[id] != _detailResumeBaseline[id]) {
        continue;
      }
      // Zero-position history must not turn a healthy next-up card into a
      // completion. Played can remain true during a real partial rewatch.
      if (candidate.resume <= Duration.zero) {
        continue;
      }
      if (_sameResumeCheckpoint(_supersededHistory[id], candidate)) {
        supersededHistory++;
        continue;
      }
      DateTime? date(MediaItem value) => DateTime.tryParse(
        '${object(value.data['UserData'])['LastPlayedDate']}',
      );
      final at = date(candidate),
          remoteAt = date(server),
          verifiedAt = before[id] == null ? null : date(before[id]!);
      if (at == null) missingDate++;
      // DatePlayed already orders this fresh batch. LastPlayedDate is optional
      // user metadata; its omission does not mean the ordered row is unwatched.
      // Compare dates when both endpoints supply them, without inventing one.
      if (at != null &&
          (remoteAt != null && remoteAt.isAfter(at) ||
              verifiedAt != null && verifiedAt.isAfter(at))) {
        olderDate++;
        continue;
      }
      // A fresh Resume checkpoint (including a backwards seek) must not be
      // overwritten by the unchanged DatePlayed observation at the same date.
      if (baselines[id] != null &&
          !_sameResumeCheckpoint(baselines[id], server) &&
          before[id] != null &&
          _sameResumeCheckpoint(_resumeObservation(before[id]!), candidate) &&
          (verifiedAt == null || at == null || !at.isAfter(verifiedAt))) {
        changedCheckpoint++;
        _supersededHistory[id] = _resumeObservation(candidate);
        changedHistory = true;
        continue;
      }
      matchedHistory++;
      if (_resumeObservation(candidate) == _resumeObservation(server)) {
        if (_detailHistory.remove(id) != null) {
          _detailResumeBaseline.remove(id);
          changedHistory = true;
        }
      } else {
        _detailHistory[id] = candidate;
        _detailResumeBaseline[id] = _resumeObservation(server);
        changedHistory = true;
      }
    }
    while (_detailHistory.length > 96) {
      final oldest = _detailHistory.keys.first;
      _detailHistory.remove(oldest);
      _detailResumeBaseline.remove(oldest);
    }
    while (_supersededHistory.length > 96) {
      _supersededHistory.remove(_supersededHistory.keys.first);
    }
    store.log.add(
      LogArea.app,
      '[HOME153] 首页观看核对：待核对系列=${series.length}；候选=${latest.length}；有效匹配=$matchedHistory；缺少可选日期=$missingDate；较旧日期拒绝=$olderDate；已改变定位记录=$changedCheckpoint；失效历史拒绝=$supersededHistory；本机播放回执=${_playbackReceipts.length}；显示校正=${changedHistory ? '有' : '无'}；未写观看进度',
    );
    _historyInput = input;
    _historyRefreshed = DateTime.now();
    if (changedHistory) {
      try {
        await _saveVerifiedHistory();
      } catch (_) {
        store.log.add(LogArea.app, '首页批量核对显示缓存未保存；当前核对结果仍保留');
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
  MediaItem _verifiedResumeItem(MediaItem server) {
    if (server.type != 'Episode') return server;
    final series = server.data['SeriesId']?.toString() ?? '';
    final verified = _detailHistory[series];
    if (verified == null ||
        !allowsResume(verified) ||
        _sameResumeCheckpoint(_supersededHistory[series], verified)) {
      return server;
    }
    DateTime? date(MediaItem item) => DateTime.tryParse(
      object(item.data['UserData'])['LastPlayedDate']?.toString() ?? '',
    );
    final remoteAt = date(server), verifiedAt = date(verified);
    if (remoteAt != null &&
        verifiedAt != null &&
        remoteAt.isAfter(verifiedAt)) {
      return server;
    }
    final older =
        remoteAt != null && verifiedAt != null && remoteAt.isBefore(verifiedAt);
    if (!older &&
        !_sameResumeCheckpoint(_detailResumeBaseline[series], server)) {
      return server;
    }
    if (server.id == verified.id) {
      return MediaItem({
        ...server.data,
        ...verified.data,
        'UserData': {
          ...object(server.data['UserData']),
          ...object(verified.data['UserData']),
        },
      });
    }
    return MediaItem({
      ...verified.data,
      for (final field in ['SeriesName', 'SeriesPrimaryImageTag'])
        if (!verified.data.containsKey(field) && server.data.containsKey(field))
          field: server.data[field],
    });
  }

  MediaItem? recentEpisode(String seriesId) {
    if (!current) return null;
    final verified = _detailHistory[seriesId];
    final recent =
        _recent.values
            .where(
              (value) =>
                  value.item.type == 'Episode' &&
                  value.item.data['SeriesId'] == seriesId,
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
    final latest = await _request(
      () => api.lastWatchedEpisode(seriesId),
      generation,
    );
    if (!current) return null;
    final local =
        _recent.values
            .where(
              (value) =>
                  value.item.type == 'Episode' &&
                  value.item.data['SeriesId'] == seriesId,
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

  /// Shared display merge; progress ownership remains in AppStore.resume.
  List<MediaItem> mergeResume(Iterable<MediaItem> entries, {int limit = 18}) {
    final serverItems = entries
        .where(allowsResume)
        .map(_verifiedResumeItem)
        .toList();
    final now = DateTime.now();
    final pending = <MediaItem>[];
    final finished = <({MediaItem item, DateTime at})>[];
    final completed = <String>{};
    final observations = _recent.values.toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    for (final observation in observations) {
      final recent = observation.item;
      if (!allowsResume(recent)) continue;
      // A pending checkpoint is durable, but it is not necessarily this
      // series' latest viewing. A newer episode observed on the server (or
      // verified in details) must not be displaced by an older local row.
      final replacedEpisode = serverItems.any((item) {
        if (item.id == recent.id ||
            recent.type != 'Episode' ||
            resumeTitleKey(item) != resumeTitleKey(recent)) {
          return false;
        }
        final at = DateTime.tryParse(
          '${object(item.data['UserData'])['LastPlayedDate']}',
        );
        return at != null && at.isAfter(observation.at);
      });
      if (replacedEpisode) continue;
      final server = serverItems
          .where((item) => item.id == recent.id)
          .firstOrNull;
      final local = store.localProgress(account, recent.id);
      final recentDate = DateTime.tryParse(
        '${object(recent.data['UserData'])['LastPlayedDate']}',
      );
      final newerServer = serverItems.any((item) {
        if (resumeTitleKey(item) != resumeTitleKey(recent)) return false;
        final date = DateTime.tryParse(
          '${object(item.data['UserData'])['LastPlayedDate']}',
        );
        return date != null && (recentDate == null || date.isAfter(recentDate));
      });
      // An explicit return to the beginning is a real viewing checkpoint,
      // even though Emby's Resume endpoint can omit a position of zero.
      // Keep only the observation bound to the last acknowledged server
      // fingerprint; a later server checkpoint or episode takes precedence.
      final restartEvidence = store.restartObserved(account, recent);
      if (restartEvidence && newerServer) continue;
      final restart =
          restartEvidence &&
          !newerServer &&
          (server == null || store.restartObserved(account, server));
      if (local == null || local == Duration.zero) {
        final done =
            store.completions.completed(account, recent) &&
            (!store.completions.superseded(account, recent.id) ||
                object(recent.data['UserData'])['Played'] == true) &&
            !store.rewatchObserved(account, recent) &&
            (recent.resume == Duration.zero ||
                (store.completions.pending(account, recent.id) &&
                    !store.completions.superseded(account, recent.id)));
        final sameTitle = serverItems
            .where((item) => resumeTitleKey(item) == resumeTitleKey(recent))
            .firstOrNull;
        final newerLocal = observations.any(
          (entry) =>
              entry.at.isAfter(observation.at) &&
              resumeTitleKey(entry.item) == resumeTitleKey(recent),
        );
        final serverAt = DateTime.tryParse(
          '${object(sameTitle?.data['UserData'])['LastPlayedDate']}',
        );
        final completedAt =
            DateTime.tryParse(
              '${object(recent.data['UserData'])['LastPlayedDate']}',
            ) ??
            observation.at;
        // Keep the last locally observed completed episode as viewing history.
        // An undated server checkpoint for the same series is authoritative
        // when its freshness cannot be compared; never hide another rewatch.
        final retainEpisode =
            recent.type.toLowerCase() == 'episode' &&
            '${recent.data['SeriesId'] ?? ''}'.trim().isNotEmpty &&
            (sameTitle == null ||
                serverAt != null ||
                (sameTitle.id == recent.id &&
                    sameTitle.resume == Duration.zero &&
                    object(sameTitle.data['UserData'])['Played'] == true));
        if (done &&
            (retainEpisode ||
                now.difference(observation.at) < const Duration(seconds: 30) ||
                store.completions.pending(account, recent.id)) &&
            !newerLocal &&
            (serverAt == null || !serverAt.isAfter(completedAt))) {
          completed.add(resumeTitleKey(recent));
          finished.add((
            item: MediaItem({
              ...recent.data,
              'UserData': {
                ...object(recent.data['UserData']),
                'Played': true,
                'PlaybackPositionTicks': 0,
              },
            }),
            at: observation.at,
          ));
          continue;
        }
      }
      final grace =
          now.difference(observation.at) < const Duration(seconds: 30);
      final sameTitleServer = serverItems
          .where((item) => resumeTitleKey(item) == resumeTitleKey(recent))
          .firstOrNull;
      final titleDate = DateTime.tryParse(
        '${object(sameTitleServer?.data['UserData'])['LastPlayedDate']}',
      );
      final confirmedEpisode =
          _playbackReceipts.containsKey(recent.id) &&
          sameTitleServer != null &&
          _sameResumeCheckpoint(
            _playbackReceipts[recent.id],
            sameTitleServer,
          ) &&
          (titleDate == null || !titleDate.isAfter(observation.at));
      final newerAcknowledgedEpisode =
          recent.type == 'Episode' &&
          recent.resume > Duration.zero &&
          sameTitleServer != null &&
          sameTitleServer.id != recent.id &&
          (confirmedEpisode ||
              recentDate != null &&
                  titleDate != null &&
                  recentDate.isAfter(titleDate));
      if (local == null &&
          !grace &&
          !restart &&
          !newerAcknowledgedEpisode &&
          !(object(recent.data['UserData'])['Played'] == true &&
              recent.resume > Duration.zero &&
              server == null &&
              !newerServer)) {
        continue;
      }
      // Pending positions always use Android's existing comparison policy,
      // including a newer PC checkpoint or a deliberate backwards seek.
      var selected = server ?? recent;
      if (local == null &&
          grace &&
          server != null &&
          (!store.restartObserved(account, recent) || restart)) {
        final serverDate = DateTime.tryParse(
          object(server.data['UserData'])['LastPlayedDate']?.toString() ?? '',
        );
        final recentDate = DateTime.tryParse(
          object(recent.data['UserData'])['LastPlayedDate']?.toString() ?? '',
        );
        // A just-read item detail may precede the Resume endpoint's update.
        // A newer server observation still wins during the display grace.
        if (serverDate == null ||
            (recentDate != null && !serverDate.isAfter(recentDate))) {
          selected = recent;
        }
      }
      final position = store.resume(account, selected).position;
      if (position <= Duration.zero && !restart) {
        completed.add(resumeTitleKey(recent));
      } else {
        pending.add(withPosition(selected, position));
      }
    }
    final merged = collapseResume([
      ...pending,
      ...serverItems.where((item) => !completed.contains(resumeTitleKey(item))),
    ], limit: 10000);
    for (final entry in finished.reversed) {
      final at = merged.indexWhere((item) {
        final time = DateTime.tryParse(
          '${object(item.data['UserData'])['LastPlayedDate']}',
        );
        return time == null || !time.isAfter(entry.at);
      });
      merged.insert(at < 0 ? merged.length : at, entry.item);
    }
    return collapseResume(merged, limit: limit);
  }

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
      detail = await _request(() => api.detail(original.id), revision);
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
    if (actualCompleted == false &&
        observed.type == 'Episode' &&
        observed.resume > Duration.zero) {
      _playbackReceipts[original.id] =
          _rawResumeObservations['${observed.data['SeriesId'] ?? ''}'];
    }
    // Keep the actual server observation for a pending restart. Only the
    // visible row projects it to the local checkpoint; changing its stored
    // fingerprint would lose a still-unsynced zero during the next refresh.
    _recent[original.id] = (item: restart ? detail : observed, at: watchedAt);
    final key = resumeTitleKey(observed);
    resume = collapseResume([
      if (completed ||
          restart ||
          (local != Duration.zero && position > Duration.zero))
        observed,
      ...resume.where((item) => resumeTitleKey(item) != key),
    ]);
    while (_recent.length > 18) {
      final oldest = _recent.keys.first;
      _recent.remove(oldest);
      _playbackReceipts.remove(oldest);
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
