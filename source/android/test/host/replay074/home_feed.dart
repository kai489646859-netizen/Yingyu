import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/resume_visibility.dart';

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
        }
      }
    } catch (_) {
      /* A corrupt optional home cache must not prevent login. */
    }
    final cached = _recent.values.toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    // Startup and refresh must apply the same progress/order policy. An old,
    // already-synced local observation must not jump ahead of the last server
    // snapshot (or resurrect an episode that the server has replaced).
    final savedResume = browse?.peek('resume:0:18');
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
    _disposed = true;
    generation++;
    super.dispose();
  }

  void suspend() {
    _reloadAfterPause =
        _reloadAfterPause ||
        loading ||
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
    if (_reloadAfterPause) {
      _reloadAfterPause = false;
      unawaited(refresh());
    }
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

  Future<void> refresh({bool force = false}) => _refreshJob ??= _refresh(
    force: force,
  ).whenComplete(() => _refreshJob = null);

  /// A user retry waits for an older refresh, then bypasses stale metadata once.
  Future<void> retry() async {
    await _refreshJob;
    if (current && !paused) await refresh(force: true);
  }

  Future<void> _refresh({bool force = false}) async {
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
        if (force && browse != null) {
          await browse!.catalogue(force: true, resourceSnapshot: true);
        } else {
          await browse?.ensureVisibility();
        }
        finishStage('目录核对');
      }
      if (force &&
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
      if (current && revision == generation) error = safeError(e);
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
        store.log.add(
          LogArea.app,
          '首页${force ? '手动' : '自动'}刷新完成：总耗时=${elapsed.elapsedMilliseconds} ms；分区=${sections.length}；'
          '方式=${force ? '服务器核对' : '按需复用缓存'}；'
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
      if (current && revision == generation) section.error = safeError(e);
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
      resume = mergeResume(page.items);
      lastResumeRefresh = DateTime.now();
    } catch (e) {
      if (current && revision == generation && mutation == _resumeMutation) {
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
  MediaItem? recentEpisode(String seriesId) {
    if (!current) return null;
    final recent =
        _recent.values
            .where(
              (value) =>
                  value.item.type == 'Episode' &&
                  value.item.data['SeriesId'] == seriesId,
            )
            .toList()
          ..sort((a, b) => b.at.compareTo(a.at));
    return recent.firstOrNull?.item ??
        resume
            .where(
              (entry) =>
                  entry.type == 'Episode' && entry.data['SeriesId'] == seriesId,
            )
            .firstOrNull;
  }

  Future<MediaItem?> lastWatchedEpisode(String seriesId) async {
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
    return selected;
  }

  /// Shared display merge; progress ownership remains in AppStore.resume.
  List<MediaItem> mergeResume(Iterable<MediaItem> entries, {int limit = 18}) {
    final serverItems = entries.where(allowsResume).toList();
    final now = DateTime.now();
    final pending = <MediaItem>[];
    final finished = <({MediaItem item, DateTime at})>[];
    final completed = <String>{};
    final observations = _recent.values.toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    for (final observation in observations) {
      final recent = observation.item;
      if (!allowsResume(recent)) continue;
      final server = serverItems
          .where((item) => item.id == recent.id)
          .firstOrNull;
      final local = store.localProgress(account, recent.id);
      if (local == null || local == Duration.zero) {
        final done =
            store.completions.completed(account, recent) &&
            !store.rewatchObserved(account, recent);
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
        if (done &&
            (now.difference(observation.at) < const Duration(seconds: 30) ||
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
      if (local == null && !grace) {
        continue;
      }
      // Pending positions always use Android's existing comparison policy,
      // including a newer PC checkpoint or a deliberate backwards seek.
      var selected = server ?? recent;
      if (local == null && grace && server != null) {
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
      if (position <= Duration.zero) {
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
    browse?.invalidateProgress(original.id);
    final revision = generation;
    final removalKey = resumeTitleKey(original);
    final removal = _removalRevisions[removalKey];
    var detail = original;
    try {
      detail = await _request(() => api.detail(original.id), revision);
    } catch (_) {
      /* The existing sync warning remains visible to the user. */
    }
    if (!current || paused || revision != generation) return;
    if (removal != _removalRevisions[removalKey]) return;
    try {
      await visibility.played(original);
    } catch (error) {
      resumeError = safeError(error);
      changed();
    }
    if (!current ||
        paused ||
        revision != generation ||
        removal != _removalRevisions[removalKey]) {
      return;
    }
    final local = store.localProgress(account, original.id);
    final position = store.resume(account, detail).position;
    final completed =
        store.completions.completed(account, detail) &&
        (local == null || local == Duration.zero) &&
        !(actualCompleted == false && position > Duration.zero);
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
    _recent[original.id] = (item: observed, at: DateTime.now());
    final key = resumeTitleKey(observed);
    resume = collapseResume([
      if (completed || (local != Duration.zero && position > Duration.zero))
        observed,
      ...resume.where((item) => resumeTitleKey(item) != key),
    ]);
    while (_recent.length > 18) {
      _recent.remove(_recent.keys.first);
    }
    changed();
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
              position > Duration.zero &&
              object(detail.data['UserData'])['Played'] == true,
        );
      }
      final saved = await store.prefs.setString(
        cacheKey,
        jsonEncode({
          'items': [
            for (final value in _recent.values)
              {
                'observedAt': value.at.toIso8601String(),
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
