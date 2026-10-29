import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'emby.dart';
import 'models.dart';
import 'catalog.dart';
import 'catalog_sort.dart';
import 'background_work.dart';
import 'home_order.dart';
import 'log.dart';
import 'library_removals.dart';
import 'image_references.dart';

/// Display metadata only. Playback always uses EmbyClient's fresh detail and
/// existing progress/route rules. Never persist paths, URLs or request headers.
Json displayMetadata(Json value) {
  const fields = {
    'Id',
    'Name',
    'SortName',
    'OriginalTitle',
    'Type',
    'IsFolder',
    'MediaType',
    'CollectionType',
    'Overview',
    'ProductionYear',
    'CommunityRating',
    'OfficialRating',
    'Genres',
    'RunTimeTicks',
    'DateCreated',
    'PremiereDate',
    'ParentId',
    'SeriesId',
    'SeriesName',
    'SeasonId',
    'IndexNumber',
    'ParentIndexNumber',
    'RecursiveItemCount',
    '_YingyuLibraryIdsV1',
    '_YingyuSortMetadataV1',
    '_YingyuSortMetadataV2',
    '_YingyuVideoMetadataV1',
    '_YingyuPeopleMetadataV1',
    'ImageTags',
    'BackdropImageTags',
    'ParentBackdropItemId',
    'ParentBackdropImageTags',
    'ParentThumbItemId',
    'ParentThumbImageTag',
    'SeriesPrimaryImageTag',
  };
  return {
    if (value['People'] is List)
      'People': [
        for (final person in objects(value['People']))
          {
            for (final key in ['Id', 'Name', 'Role', 'Type', 'PrimaryImageTag'])
              if (person[key] is String) key: person[key],
            if (object(person['ImageTags'])['Primary'] is String)
              'ImageTags': {'Primary': object(person['ImageTags'])['Primary']},
            if (person['ProviderIds'] is Map)
              'ProviderIds': {
                for (final id in object(person['ProviderIds']).entries)
                  if (id.key.toLowerCase() == 'tmdb' &&
                      RegExp(r'^[0-9]+$').hasMatch(id.value.toString()))
                    id.key: id.value.toString(),
              },
          },
      ],
    if (value['ProviderIds'] is Map)
      'ProviderIds': {
        for (final entry in object(value['ProviderIds']).entries)
          if (entry.key.toLowerCase() == 'tmdb' &&
              RegExp(r'^[0-9]+$').hasMatch(entry.value.toString()))
            entry.key: entry.value.toString(),
      },
    for (final key in fields)
      if (value.containsKey(key)) key: value[key],
    if (value[titleKeysField] is Map)
      titleKeysField: {
        for (final key in ['title', 'upper', 'initials', 'full', 'letter'])
          if (value[titleKeysField][key] is String)
            key: value[titleKeysField][key],
      },
    if (value['UserData'] is Map)
      'UserData': {
        for (final key in [
          'PlaybackPositionTicks',
          'Played',
          'LastPlayedDate',
          'PlayCount',
          'IsFavorite',
          'Likes',
          'Rating',
        ])
          if (object(value['UserData']).containsKey(key))
            key: value['UserData'][key],
      },
    if (value['MediaSources'] is List)
      'MediaSources': [
        for (final source in objects(value['MediaSources']))
          {
            for (final key in [
              'Id',
              'Name',
              'Container',
              'VideoType',
              'Bitrate',
            ])
              if (source.containsKey(key)) key: source[key],
            if (source['MediaStreams'] is List)
              'MediaStreams': displayVideoStreams(source['MediaStreams']),
          },
      ],
    if (value['MediaStreams'] is List)
      'MediaStreams': displayVideoStreams(value['MediaStreams']),
  };
}

List<Json> displayVideoStreams(dynamic value) => [
  for (final stream in objects(value))
    if (stream['Type'] == 'Video')
      {
        for (final key in [
          'Type',
          'Width',
          'Height',
          'Codec',
          'VideoRange',
          'VideoRangeType',
          'BitRate',
          'Profile',
          'DolbyVisionProfile',
        ])
          if (stream.containsKey(key)) key: stream[key],
      },
];

class BrowsePreferences extends ChangeNotifier {
  BrowsePreferences(this.prefs);
  final SharedPreferences prefs;
  static const sorts = [
    'DateCreated',
    'PremiereDate',
    'CommunityRating',
    'alphabet',
  ];
  static const orderKey = 'yingyu.browse.order.v2';
  List<dynamic>? get _order {
    try {
      final value = jsonDecode(prefs.getString(orderKey) ?? 'null');
      if (value is List &&
          value.length == 2 &&
          sorts.contains(value[0]) &&
          value[1] is bool) {
        return value;
      }
    } catch (_) {
      /* Fall back to the existing preference. */
    }
    return null;
  }

  String get sort {
    return _order?[0] as String? ??
        normalizeCatalogSort(prefs.getString('yingyu.browse.sort.v1'));
  }

  bool get descending =>
      _order?[1] as bool? ??
      const [
        'DateCreated',
        'CommunityRating',
        'ProductionYear',
      ].contains(prefs.getString('yingyu.browse.sort.v1'));

  Future<void> setSort(String value, {bool? descending}) async {
    if (!sorts.contains(value)) return;
    if (!await prefs.setString(
      orderKey,
      jsonEncode([value, descending ?? this.descending]),
    )) {
      throw const AppFailure('排序偏好保存失败');
    }
    notifyListeners();
  }

  int get minutes {
    final value = prefs.getInt('yingyu.browse.minutes.v1') ?? 5;
    return const [5, 15, 30].contains(value) ? value : 5;
  }

  Duration get interval => Duration(minutes: minutes);
  Future<void> setMinutes(int value) async {
    if (!const [5, 15, 30].contains(value)) return;
    if (!await prefs.setInt('yingyu.browse.minutes.v1', value)) {
      throw const AppFailure('刷新间隔保存失败');
    }
    notifyListeners();
  }
}

class BrowseRecord {
  BrowseRecord(
    this.items,
    this.total,
    this.at, {
    this.scopes,
    this.membershipVerified = false,
  });
  final List<MediaItem> items;
  final int total;
  final DateTime at;
  final List<String>? scopes;
  final bool membershipVerified;
  ItemPage get page => CataloguePage(
    items,
    total,
    scopes: scopes,
    membershipVerified: membershipVerified,
  );
}

class CataloguePage extends ItemPage {
  CataloguePage(
    super.items,
    super.total, {
    this.scopes,
    this.membershipVerified = false,
    this.complete = false,
    this.resources,
  });
  final List<String>? scopes;
  final bool membershipVerified;
  final bool complete;
  final List<MediaItem>? resources;
}

class BrowseCache {
  BrowseCache(
    this.prefs, {
    this.maxBytes = 8 * 1024 * 1024,
    this.maxEntries = 96,
    this.images,
  }) {
    try {
      final saved = prefs.getString(storageKey);
      if (saved != null && utf8.encode(saved).length <= maxBytes) {
        final data = object(jsonDecode(saved));
        for (final entry in data.entries.take(maxEntries)) {
          final value = object(entry.value);
          final at = DateTime.tryParse(value['at']?.toString() ?? '');
          if (at != null) {
            records[entry.key] = BrowseRecord(
              objects(
                value['items'],
              ).map((item) => MediaItem(displayMetadata(item))).toList(),
              integer(value['total']),
              at,
              scopes: value['scopes'] is List
                  ? (value['scopes'] as List).whereType<String>().toList()
                  : null,
            );
          }
        }
      }
    } catch (_) {
      /* Optional cache corruption must not prevent login. */
    }
  }
  static const storageKey = 'yingyu.browse.cache.v1';
  final ImageReferences? images;
  bool _imagesSeeded = false;
  void seedImages() {
    if (_imagesSeeded || images == null) return;
    _imagesSeeded = true;
    for (final entry in records.entries) {
      final parts = jsonDecode(entry.key);
      if (parts is! List || parts.length != 3) continue;
      images!.observe(
        Session(
          base: Uri.parse(parts[0] as String),
          userId: parts[1] as String,
          token: '',
          username: '',
          deviceId: '',
        ),
        entry.value.items,
      );
    }
  }

  final SharedPreferences prefs;
  final int maxBytes, maxEntries;
  final records = <String, BrowseRecord>{};
  Future<void> _write = Future.value();
  int _batchDepth = 0;
  bool _batchDirty = false;
  // A single refresh can update many small pages. Keep its in-memory results
  // immediately, then encode/write the complete cache once before it finishes.
  void beginBatch() => _batchDepth++;
  Future<void> endBatch() async {
    assert(_batchDepth > 0);
    _batchDepth--;
    if (_batchDepth == 0 && _batchDirty) {
      _batchDirty = false;
      await persistRecords();
    }
  }

  String? warning;
  BrowseRecord? get(String key) {
    final value = records.remove(key);
    if (value != null) records[key] = value;
    return value;
  }

  Future<void> put(String key, ItemPage page, DateTime at) async {
    if (images != null) {
      seedImages();
      final parts = jsonDecode(key);
      if (parts is List && parts.length == 3) {
        images!.observe(
          Session(
            base: Uri.parse(parts[0] as String),
            userId: parts[1] as String,
            token: '',
            username: '',
            deviceId: '',
          ),
          page.items,
        );
      }
    }
    records.remove(key);
    records[key] = BrowseRecord(
      page.items.map((item) => MediaItem(displayMetadata(item.data))).toList(),
      page.total,
      at,
      scopes: page is CataloguePage ? page.scopes : null,
      membershipVerified: page is CataloguePage && page.membershipVerified,
    );
    while (records.length > maxEntries) {
      records.remove(records.keys.first);
    }
    if (_batchDepth > 0) {
      _batchDirty = true;
      return;
    }
    final snapshot = Map<String, BrowseRecord>.of(records);
    final large =
        snapshot.values.fold(0, (n, value) => n + value.items.length) > 512;
    await (_write = _write.then((_) async {
      final (text, removed) = large
          ? await compute(_encodeBrowseSnapshot, (snapshot, maxBytes))
          : _encodeBrowseSnapshot((snapshot, maxBytes));
      for (final key in removed) {
        if (identical(records[key], snapshot[key])) records.remove(key);
      }
      await _persist(text);
    }));
  }

  Future<void> _persist(String text) async {
    try {
      warning = await prefs.setString(storageKey, text) ? null : '浏览缓存保存失败';
    } catch (_) {
      warning = '浏览缓存保存失败';
    }
  }

  Future<void> _save(String text) {
    // Serialize writes so a slow older save cannot replace newer metadata.
    return _write = _write.then((_) => _persist(text));
  }

  Future<void> clear() async {
    records.clear();
    await _save('{}');
  }

  Future<void> persistRecords() async {
    if (_batchDepth > 0) {
      _batchDirty = true;
      return;
    }
    final snapshot = Map<String, BrowseRecord>.of(records);
    await (_write = _write.then((_) async {
      final (text, removed) = await compute(_encodeBrowseSnapshot, (
        snapshot,
        maxBytes,
      ));
      for (final key in removed) {
        if (identical(records[key], snapshot[key])) records.remove(key);
      }
      await _persist(text);
    }));
    if (warning != null) throw AppFailure(warning!);
  }
}

(String, List<String>) _encodeBrowseSnapshot(
  (Map<String, BrowseRecord>, int) input,
) {
  final (snapshot, limit) = input;
  final parts = <String, String>{}, lengths = <String, int>{};
  var bytes = 2;
  for (final entry in snapshot.entries) {
    final part =
        '${jsonEncode(entry.key)}:${jsonEncode({'at': entry.value.at.toIso8601String(), 'total': entry.value.total, if (entry.value.scopes != null) 'scopes': entry.value.scopes, 'items': entry.value.items.map((item) => item.data).toList()})}';
    parts[entry.key] = part;
    lengths[entry.key] = utf8.encode(part).length;
    bytes += lengths[entry.key]! + (parts.length > 1 ? 1 : 0);
  }
  final removed = <String>[];
  while (bytes > limit && parts.isNotEmpty) {
    final key = parts.keys.first;
    bytes -= lengths[key]! + (parts.length > 1 ? 1 : 0);
    parts.remove(key);
    removed.add(key);
  }
  return ('{${parts.values.join(',')}}', removed);
}

/// Shared queue for browsing only: one request at a time, request coalescing,
/// minimum spacing and server failure cooldown. Native playback is untouched.
class BrowseRepository {
  BrowseRepository(
    this.api,
    this.cache,
    this.preferences, {
    DateTime Function()? now,
    this.spacing = const Duration(milliseconds: 350),
    this.visibility,
  }) : account = api.session!,
       now = now ?? DateTime.now {
    lastConnectionRecovery = api.connection.recovery;
    api.connection.addListener(checkConnectionRecovery);
    visibility?.addListener(visibilityChanged);
    Future.microtask(visibilityChanged);
  }
  final EmbyClient api;
  final BrowseCache cache;
  final BrowsePreferences preferences;
  final Session account;
  final DateTime Function() now;
  final Duration spacing;
  final HomeOrder? visibility;
  String? _visibilitySelection;
  Future<void>? _visibilityJob;
  bool _visibilityAfterPause = false;
  void visibilityChanged() {
    if (!current || visibility == null) return;
    final ids = visibility!.hidden(account).toList()..sort();
    final selection = jsonEncode(ids);
    if (selection == _visibilitySelection) return;
    _visibilitySelection = selection;
    if (visibility!.filtering(account)) ensureVisibility();
  }

  Future<void> ensureVisibility({bool force = false}) {
    final policy = visibility;
    if (!current ||
        paused ||
        policy == null ||
        !policy.filtering(account) ||
        (!force && policy.ready(account))) {
      return Future.value();
    }
    return _visibilityJob ??= _resolveVisibility(force).whenComplete(() {
      _visibilityJob = null;
      if (_visibilityAfterPause && current && !paused) {
        _visibilityAfterPause = false;
        ensureVisibility();
      }
    });
  }

  Future<void> _resolveVisibility(bool force) async {
    visibility!.beginResolution(account);
    try {
      await libraries();
      final page = await catalogue(force: force);
      if (!current || paused) return;
      if (page is! CataloguePage ||
          page.scopes == null ||
          !page.membershipVerified) {
        throw const AppFailure('媒体库范围尚未核对完整，请刷新后重试');
      }
    } catch (e) {
      if (current) {
        visibility!.failResolution(
          account,
          e is BackgroundPaused ? '可见范围核对已暂停，返回后重试' : safeError(e),
        );
      }
    }
  }

  BackgroundWork? _warmingScope;
  Future<void>? _warmingJob;
  void cancelSearchWarmup() => _warmingScope?.pause(this, true);
  Future<void> warmSearchCatalogue() => _warmingJob ??= _warmSearchCatalogue()
      .whenComplete(() => _warmingJob = null);
  Future<void> _warmSearchCatalogue() async {
    if (!current || paused || fresh(peekSharedCatalogue(null))) return;
    final work = BackgroundWork();
    _warmingScope = work;
    void lifecycle() =>
        work.pause(api.backgroundWork, api.backgroundWork.paused);
    api.backgroundWork.addListener(lifecycle);
    lifecycle();
    try {
      await catalogue(
        allowed: () => current && !paused && !work.paused,
        requestWork: work,
      );
    } catch (_) {
      // Optional metadata preloading. Opening search retries normally and
      // retains its real error if the server is still unavailable.
    } finally {
      api.backgroundWork.removeListener(lifecycle);
      if (identical(_warmingScope, work)) _warmingScope = null;
      work.dispose();
    }
  }

  final _pending = <String, Future<ItemPage>>{};
  final _confirmationWindows = <Set<String>>{};
  Set<String> beginConfirmation() {
    final items = <String>{};
    _confirmationWindows.add(items);
    return items;
  }

  void endConfirmation(Set<String> items) => _confirmationWindows.remove(items);
  Future<void> _tail = Future.value();
  DateTime? _lastStart, _retryAt;
  bool paused = false, disposed = false;
  int failures = 0, epoch = 0;
  int resumeRevision = 0;
  int reconciliationRevision = 0;
  void markViewsStale() => reconciliationRevision++;
  Future<void> Function(Set<String>)? onRemoved;
  final _syncRemoved = <String>{};
  final _catalogueCommits = Expando<Future<void>>();
  Iterable<MediaItem> Function()? extraItems;

  List<MediaItem> knownItems() => [
    for (final entry in cache.records.entries)
      if (entry.key.startsWith(
        '${jsonEncode([account.base.toString(), account.userId]).replaceFirst(RegExp(r'\]$'), '')},',
      ))
        ...entry.value.items,
    ...?extraItems?.call(),
  ];

  /// Local set difference only. The proof must come from a fresh, complete,
  /// unfiltered directory response, never from Resume, Latest or a search.
  Future<void> reconcileSnapshot(
    List<MediaItem> before,
    ItemPage page, {
    String? parent,
    String? season,
    bool includesEpisodes = false,
  }) async {
    final ids = page.items.map((item) => item.id).toSet();
    final missing = <String>{};
    for (final item in before) {
      if (season != null) {
        if (item.type == 'Episode' &&
            item.data['SeasonId'] == season &&
            item.data['SeriesId'] == parent &&
            !ids.contains(item.id)) {
          missing.add(item.id);
        }
        continue;
      }
      final within =
          parent == null ||
          (item.data['_YingyuLibraryIdsV1'] as List?)?.contains(parent) == true;
      if (!within) continue;
      if ((const ['Movie', 'Series', 'Video'].contains(item.type) ||
              includesEpisodes &&
                  const ['Episode', 'Season'].contains(item.type)) &&
          !ids.contains(item.id)) {
        // A resource can belong to more than one library. A partial scope
        // cannot delete its other membership or shared image reference.
        final memberships =
            (item.data['_YingyuLibraryIdsV1'] as List? ?? const []);
        if (parent == null || memberships.length == 1) missing.add(item.id);
      }
      if (!includesEpisodes && parent == null && item.type == 'Episode') {
        final series = item.data['SeriesId'];
        if (series is String && series.isNotEmpty && !ids.contains(series)) {
          missing.add(series);
        }
      }
    }
    // A live child proves its referenced parent has not become an orphan.
    // Some server versions omit a virtual season from a flat response.
    missing.removeAll({
      for (final item in page.items)
        ...[
          item.data['SeriesId'],
          item.data['SeasonId'],
          item.data['ParentId'],
        ].whereType<String>(),
    });
    if (missing.isEmpty) return;
    await acceptLibraryChanges(missing, ids, source: '完整目录');
    _syncRemoved.addAll(missing);
    reconciliationRevision++;
    await onRemoved?.call(missing);
  }

  Future<Set<String>> finishLocalSync() async {
    await cache.images?.sweep();
    final removed = Set<String>.of(_syncRemoved);
    _syncRemoved.clear();
    return removed;
  }

  int lastConnectionRecovery = 0;
  void checkConnectionRecovery() {
    if (api.connection.recovery > lastConnectionRecovery) {
      lastConnectionRecovery = api.connection.recovery;
      connectionRecovered();
    }
  }

  bool get current => !disposed && identical(account, api.session);
  String key(String query) =>
      jsonEncode([account.base.toString(), account.userId, query]);
  BrowseRecord? peek(String query) => cache.get(key(query));
  BrowseRecord? peekCatalogue(String? parent, String sort) {
    final own = peek(catalogueKey(parent, sort));
    if (parent == null) return own;
    final all = peek(catalogueKey(null, sort));
    if (all?.scopes?.contains(parent) != true ||
        own != null && own.at.isAfter(all!.at)) {
      return own;
    }
    final rows = all!.items
        .where(
          (item) =>
              (item.data['_YingyuLibraryIdsV1'] as List?)?.contains(parent) ==
              true,
        )
        .toList();
    return BrowseRecord(rows, rows.length, all.at);
  }

  /// Older releases stored a complete catalogue under each server sort. Reuse
  /// those rows on startup until the normal refresh fills the shared name cache.
  BrowseRecord? peekSharedCatalogue(String? parent) {
    final canonical = peekCatalogue(parent, 'alphabet');
    if (canonical != null) return canonical;
    BrowseRecord? result;
    for (final sort in [
      '',
      'SortName',
      'DateCreated',
      'CommunityRating',
      'ProductionYear',
    ]) {
      final candidate = peekCatalogue(parent, sort);
      if (candidate != null &&
          (result == null || candidate.at.isAfter(result.at))) {
        result = candidate;
      }
    }
    return result;
  }

  bool fresh(BrowseRecord? record) =>
      record != null &&
      now().difference(record.at) < preferences.interval &&
      !record.at.isAfter(now());
  void suspend() {
    if (paused) return;
    paused = true;
    _visibilityAfterPause = _visibilityJob != null;
    epoch++;
    api.backgroundWork.pause(this, true);
  }

  void activate() {
    paused = false;
    api.backgroundWork.pause(this, false);
    if (_visibilityJob != null) _visibilityAfterPause = true;
    ensureVisibility();
  }

  void connectionRecovered() {
    failures = 0;
    _retryAt = null;
  }

  /// A deletion notification is already authoritative. No HTTP confirmation,
  /// no list reload, and no invalidation of another account's cache.
  Future<void> acceptLibraryChanges(
    Set<String> removed,
    Set<String> added, {
    String source = '服务器通知',
  }) async {
    if (!current) return;
    // Fence old HTTP replies before awaiting any preference write. Otherwise
    // one could clear the new deletion mark while its save is still pending.
    final cacheWrite = acceptRemovals(removed);
    try {
      await visibility?.removals.apply(
        account,
        removed: removed,
        added: added,
        log: api.log,
      );
    } finally {
      await cacheWrite;
    }
    await cache.images?.remove(account, removed);
    if (current && (removed.isNotEmpty || added.isNotEmpty)) {
      api.log?.add(
        LogArea.app,
        '资源变更已处理：来源=$source；删除 ID=${removed.length}；存在 ID=${added.length}；'
        '展示缓存已核对，本机观看记录保留；图片清理=${cache.images?.warning ?? '按引用规则处理，未统计文件数'}',
      );
    }
  }

  Future<void> acceptRemovals(Set<String> removed) async {
    if (!current || removed.isEmpty) return;
    epoch++;
    _pending.clear();
    for (final entry in cache.records.entries.toList()) {
      final parts = jsonDecode(entry.key);
      if (parts is! List ||
          parts.length != 3 ||
          parts[0] != account.base.toString() ||
          parts[1] != account.userId) {
        continue;
      }
      final before = entry.value;
      final rows = before.items
          .where((item) => !LibraryRemovals.references(item, removed))
          .toList();
      if (rows.length == before.items.length) continue;
      if (rows.isEmpty && (parts[2] as String).startsWith('detail:')) {
        cache.records.remove(entry.key);
      } else {
        cache.records[entry.key] = BrowseRecord(
          rows,
          (before.total - before.items.length + rows.length).clamp(
            0,
            before.total,
          ),
          before.at,
          scopes: before.scopes?.where((id) => !removed.contains(id)).toList(),
          membershipVerified: before.membershipVerified,
        );
      }
    }
    await cache.persistRecords();
  }

  void dispose() {
    cancelSearchWarmup();
    disposed = true;
    api.connection.removeListener(checkConnectionRecovery);
    visibility?.removeListener(visibilityChanged);
    epoch++;
    api.backgroundWork.pause(this, false);
  }

  Future<ItemPage> read(
    String query,
    Future<ItemPage> Function() fetch, {
    bool force = false,
    bool Function()? allowed,
    BackgroundWork? requestWork,
  }) {
    if (!current) return Future.error(const AppFailure('浏览会话已关闭'));
    final saved = peek(query);
    if (!force && fresh(saved)) return Future.value(saved!.page);
    return _pending.putIfAbsent(query, () {
      final revision = epoch;
      final resumeAt = resumeRevision;
      bool resumeChanged() =>
          query.startsWith('resume:') && resumeAt != resumeRevision;
      final task = _tail.then((_) async {
        void check() {
          if (!current ||
              paused ||
              revision != epoch ||
              resumeChanged() ||
              allowed?.call() == false) {
            throw const BackgroundPaused();
          }
          if (_retryAt != null && now().isBefore(_retryAt!)) {
            throw const AppFailure('服务器暂时不可用，稍后自动重试；已保留本机缓存');
          }
        }

        check();
        if (_lastStart != null) {
          final wait = spacing - now().difference(_lastStart!);
          if (wait > Duration.zero) await Future<void>.delayed(wait);
        }
        check();
        _lastStart = now();
        ItemPage page;
        try {
          page = await (requestWork ?? api.backgroundWork).run(fetch);
          failures = 0;
          _retryAt = null;
        } catch (error) {
          if (error is BackgroundPaused) rethrow;
          if (error is! AppFailure ||
              error.status == null ||
              error.status == 429 ||
              error.status! >= 500) {
            failures = (failures + 1).clamp(1, 4);
            _retryAt = now().add(Duration(seconds: 30 * (1 << (failures - 1))));
          }
          rethrow;
        }
        if (!current ||
            paused ||
            revision != epoch ||
            resumeChanged() ||
            allowed?.call() == false ||
            requestWork?.paused == true) {
          throw const BackgroundPaused();
        }
        for (final window in _confirmationWindows) {
          window.addAll(page.items.map((item) => item.id));
        }
        // An offline client can miss an ItemsAdded event. Only a fresh reply
        // whose request survived the deletion epoch may restore exact IDs.
        final removed = visibility?.removals;
        if (removed != null && removed.hasConfirmations(account)) {
          final values = page is CataloguePage
              ? page.resources ?? page.items
              : page.items;
          final restored = values
              .map((item) => item.id)
              .where((id) => removed.needsConfirmation(account, id))
              .toSet();
          if (restored.isNotEmpty) {
            await removed.apply(account, added: restored, log: api.log);
          }
          if (!current || paused || revision != epoch) {
            throw const BackgroundPaused();
          }
        }
        cache.images?.observe(account, page.items);
        await cache.put(key(query), page, now());
        await cache.images?.flush();
        if (resumeChanged()) throw const BackgroundPaused();
        return page;
      });
      _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      late Future<ItemPage> result;
      result = task.whenComplete(() {
        if (identical(_pending[query], result)) _pending.remove(query);
      });
      return result;
    });
  }

  Future<List<MediaItem>> libraries({bool force = false}) async {
    final values = (await read('views', () async {
      final items = await api.libraries();
      return ItemPage(items, items.length);
    }, force: force)).items;
    if (current) visibility?.observeLibraries(account, values.map((v) => v.id));
    return values;
  }

  Future<Set<String>>? _reconciling;
  Set<String> _reconcilingIds = {};
  Future<Set<String>> reconcileCachedItems({
    Iterable<String> extraIds = const [],
    Set<String> confirmedIds = const {},
  }) {
    final extra = extraIds.where((id) => id.isNotEmpty).toSet();
    if (_reconciling != null) {
      final running = _reconciling!;
      if (extra.every(_reconcilingIds.contains)) return running;
      return running.then(
        (missing) async => {
          ...missing,
          ...await reconcileCachedItems(
            extraIds: extra,
            confirmedIds: confirmedIds,
          ),
        },
      );
    }
    _reconcilingIds = extra;
    // Share the metadata queue, spacing and failure cooldown with normal reads.
    final task = _tail.then((_) => _reconcileCachedItems(extra, confirmedIds));
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return _reconciling = task.whenComplete(() => _reconciling = null);
  }

  Future<Set<String>> _reconcileCachedItems(
    Set<String> ids,
    Set<String> confirmedIds,
  ) async {
    final revision = epoch;
    void check() {
      if (!current || paused || revision != epoch) {
        throw const BackgroundPaused();
      }
      if (_retryAt != null && now().isBefore(_retryAt!)) {
        throw const AppFailure('服务器暂时不可用，稍后重试；原缓存已保留');
      }
    }

    Future<T> auditRead<T>(Future<T> Function() fetch) async {
      check();
      if (_lastStart != null) {
        final wait = spacing - now().difference(_lastStart!);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      check();
      _lastStart = now();
      try {
        final value = await api.backgroundWork.run(fetch);
        check();
        return value;
      } catch (error) {
        if (error is BackgroundPaused) rethrow;
        if (error is! AppFailure ||
            error.status == null ||
            error.status == 429 ||
            error.status! >= 500) {
          failures = (failures + 1).clamp(1, 4);
          _retryAt = now().add(Duration(seconds: 30 * (1 << (failures - 1))));
        }
        rethrow;
      }
    }

    check();
    final snapshot = <String, BrowseRecord>{};
    for (final entry in cache.records.entries) {
      final parts = jsonDecode(entry.key);
      if (parts is List &&
          parts.length == 3 &&
          parts[0] == account.base.toString() &&
          parts[1] == account.userId &&
          parts[2] != 'views') {
        snapshot[entry.key] = entry.value;
        ids.addAll(entry.value.items.map((item) => item.id));
      }
    }
    ids.remove('');
    // A live response in this refresh already proves presence. Rechecking the
    // same ID adds no evidence, especially after a full membership catalogue.
    ids.removeAll(confirmedIds);
    final requested = ids.toList(), missing = <String>{};
    final transport = api.forAccount(account);
    for (final batch in itemLookupBatches(requested)) {
      final found = await auditRead(() => transport.existingItemIds(batch));
      final omitted = batch.where((id) => !found.contains(id)).toList();
      if (omitted.length >= 8) {
        // One alternative, documented bulk route. Keep the original queue and
        // request spacing; never compensate for a missing batch with a burst.
        try {
          found.addAll(
            await auditRead(
              () => transport.existingItemIds(omitted, direct: true),
            ),
          );
        } on AppFailure catch (error) {
          if (error.status != 404 && error.status != 405) rethrow;
        }
      }
      check();
      missing.addAll(batch.where((id) => !found.contains(id)));
      api.log?.add(
        LogArea.app,
        '缓存批量核对：请求=${batch.length}；确认存在=${found.length}；待单项核对=${missing.length}',
      );
      if (missing.length > 8) {
        // A server returning empty/unsupported bulk results must not cause
        // hundreds of per-item requests. No deletion has been committed.
        throw const AppFailure('部分缓存暂时无法核实，已停止额外查询并保留缓存');
      }
    }
    // Views are virtual folder entries, not evidence of deleted media. A batch
    // miss must also be confirmed by a resource-specific 404/410 before commit.
    for (final id in missing.toList()) {
      final exists = await auditRead(() => transport.itemExists(id));
      if (exists) missing.remove(id);
    }
    failures = 0;
    _retryAt = null;
    // Commit only after every batch succeeds. Invalidate an affected page as
    // a unit so stale offsets/totals cannot be mistaken for a complete list.
    check();
    if (missing.isNotEmpty) {
      epoch++;
      reconciliationRevision++;
      _pending.clear();
      for (final entry in snapshot.entries) {
        if (identical(cache.records[entry.key], entry.value) &&
            entry.value.items.any((item) => missing.contains(item.id))) {
          cache.records.remove(entry.key);
        }
      }
      await cache.persistRecords();
    }
    return missing;
  }

  Future<List<MediaItem>> latest(String id, {bool force = false}) async =>
      (await read('latest:$id', () async {
        final items = await api.latestItems(id);
        return ItemPage(items, items.length);
      }, force: force)).items;
  Future<ItemPage> resume({
    int start = 0,
    int limit = 18,
    bool force = false,
  }) => read(
    'resume:$start:$limit',
    () => api.resumeItems(start: start, limit: limit),
    force: force,
  );
  Future<ItemPage> catalogue({
    String? parent,
    String sort = 'alphabet',
    bool force = false,
    bool Function()? allowed,
    BackgroundWork? requestWork,
    bool resourceSnapshot = false,
  }) async {
    final before = knownItems();
    final requestEpoch = epoch;
    final page = await _catalogue(
      parent: parent,
      sort: sort,
      force: force,
      allowed: allowed,
      requestWork: requestWork,
      resourceSnapshot: resourceSnapshot,
    );
    if (!current ||
        paused ||
        requestEpoch != epoch && _catalogueCommits[page] == null) {
      throw const BackgroundPaused();
    }
    if (page is CataloguePage && page.complete) {
      await (_catalogueCommits[page] ??= () async {
        final resources = page.resources;
        cache.images?.observe(account, resources ?? page.items);
        await reconcileSnapshot(
          before,
          resources == null ? page : ItemPage(resources, resources.length),
          parent: parent,
          includesEpisodes: resources != null,
        );
        if (resourceSnapshot) {
          cache.records.remove(key('${catalogueKey(parent, sort)}:resources'));
          await cache.put(key(catalogueKey(parent, sort)), page, now());
        }
        await cache.images?.flush();
      }());
    }
    if (current &&
        parent == null &&
        page is CataloguePage &&
        page.scopes != null &&
        page.membershipVerified) {
      visibility?.resolveMembership(
        account,
        page.resources ?? page.items,
        page.scopes!,
      );
    }
    return page;
  }

  Future<ItemPage> _catalogue({
    String? parent,
    String sort = 'alphabet',
    bool force = false,
    bool Function()? allowed,
    BackgroundWork? requestWork,
    bool resourceSnapshot = false,
  }) {
    if (!current) return Future.error(const AppFailure('浏览会话已关闭'));
    final query =
        '${catalogueKey(parent, sort)}${resourceSnapshot ? ':resources' : ''}';
    final canonical = peekCatalogue(parent, sort);
    final previous = sort == 'alphabet'
        ? canonical ?? peekSharedCatalogue(parent)
        : canonical;
    final views = peek('views')?.items ?? const <MediaItem>[];
    final partitioned =
        parent == null && sort == 'alphabet' && views.isNotEmpty;
    final strictMembership = visibility?.filtering(account) ?? false;
    final needsMembership =
        partitioned &&
        (previous?.scopes == null ||
            (strictMembership && previous?.membershipVerified != true));
    if (!resourceSnapshot && !force && !needsMembership && fresh(previous)) {
      if (sort == 'alphabet' && canonical == null) {
        final prepared = previous!.items.length > 512
            ? compute(prepareCatalog, previous.items)
            : Future.value(prepareCatalog(previous.items));
        return prepared.then((items) async {
          final page = CataloguePage(
            items,
            previous.total,
            scopes: previous.scopes,
            membershipVerified: previous.membershipVerified,
          );
          if (!current || paused || allowed?.call() == false) {
            throw const BackgroundPaused();
          }
          await cache.put(key(query), page, previous.at);
          return page;
        });
      }
      return Future.value(previous!.page);
    }
    return read(
      query,
      () async {
        final gathered = <MediaItem>[];
        final byIdIndex = <String, int>{};
        var membershipVerified =
            partitioned &&
            views.every((v) => v.id.isNotEmpty) &&
            views.map((v) => v.id).toSet().length == views.length;
        final parents = partitioned
            ? views.map((v) => v.id).toList()
            : <String?>[parent];
        for (final scope in parents) {
          if (scope != parents.first) await Future<void>.delayed(spacing);
          var start = 0;
          int? expectedTotal;
          final scopeIds = <String>{};
          while (true) {
            if (!current || paused || allowed?.call() == false) {
              throw const BackgroundPaused();
            }
            // Omit Limit to fetch the complete lightweight catalogue. If a server
            // imposes its own cap, continue internally without a user paging step.
            final page = await api.browseItems(
              parent: scope,
              start: start,
              limit: null,
              sort: sort == 'alphabet' ? '' : sort,
              minimal: true,
              resourceSnapshot: resourceSnapshot,
            );
            if (!current || paused || allowed?.call() == false) {
              throw const BackgroundPaused();
            }
            final added = page.items
                .where((item) => scopeIds.add(item.id))
                .toList();
            expectedTotal ??= page.total;
            final validPage =
                page.countKnown &&
                page.total == expectedTotal &&
                added.length == page.items.length &&
                page.items.every((item) => item.id.isNotEmpty) &&
                start + page.items.length <= page.total;
            membershipVerified = membershipVerified && validPage;
            if (!validPage) {
              throw const AppFailure('媒体库目录返回不完整，原记录已保留，请稍后刷新');
            }
            for (final item in added) {
              final at = byIdIndex[item.id];
              final known = at == null
                  ? const <String>[]
                  : (gathered[at].data['_YingyuLibraryIdsV1'] as List?)
                            ?.cast<String>() ??
                        const <String>[];
              final value = MediaItem({
                ...item.data,
                // V2 means year/date/rating were explicitly requested. V1 could
                // incorrectly mark a reduced DTO as complete on some servers.
                // A genuinely absent value stays unknown without a retry loop.
                '_YingyuSortMetadataV1': true,
                '_YingyuSortMetadataV2': true,
                if (scope != null)
                  '_YingyuLibraryIdsV1': {...known, scope}.toList(),
              });
              if (at == null) {
                byIdIndex[item.id] = gathered.length;
                gathered.add(value);
              } else {
                gathered[at] = value;
              }
            }
            start += page.items.length;
            if (page.total <= start) break;
            if (added.isEmpty) throw const AppFailure('媒体库资料返回不完整，请重试');
            await Future<void>.delayed(spacing);
          }
        }
        final resources = resourceSnapshot
            ? List<MediaItem>.of(gathered)
            : null;
        if (resourceSnapshot) {
          gathered.removeWhere(
            (item) => const ['Episode', 'Season'].contains(item.type),
          );
        }
        final scopes = partitioned
            ? parents.whereType<String>().toList()
            : null;
        final byId = {for (final item in gathered) item.id: item};
        final old = previous?.items ?? <MediaItem>[];
        final unchanged =
            old.length == gathered.length &&
            old.every(
              (item) =>
                  byId[item.id]?.title == item.title &&
                  object(item.data[titleKeysField])['title'] == item.title,
            );
        if (unchanged) {
          final order = sort == 'alphabet'
              ? canonical == null
                    ? prepareCatalog(old)
                    : old
              : gathered;
          final keys = {
            for (final item in old) item.id: item.data[titleKeysField],
          };
          return CataloguePage(
            [
              for (final item in order)
                MediaItem({
                  ...byId[item.id]!.data,
                  titleKeysField: keys[item.id],
                }),
            ],
            gathered.length,
            scopes: scopes,
            membershipVerified: membershipVerified,
            complete: true,
            resources: resources,
          );
        }
        final keys = {
          for (final item in old) item.id: item.data[titleKeysField],
        };
        final sorted = await compute(
          sort == 'alphabet' ? prepareCatalog : prepareServerCatalog,
          [
            for (final item in gathered)
              MediaItem({
                ...item.data,
                if (keys[item.id] != null) titleKeysField: keys[item.id],
              }),
          ],
        );
        return CataloguePage(
          sorted,
          sorted.length,
          scopes: scopes,
          membershipVerified: membershipVerified,
          complete: true,
          resources: resources,
        );
      },
      force: force || needsMembership || resourceSnapshot,
      allowed: allowed,
      requestWork: requestWork,
    );
  }

  static String catalogueKey(String? parent, String sort) =>
      'catalogue:v1:${jsonEncode([parent, sort])}';

  static String episodeCatalogueKey(String id, String season) =>
      'episode-catalogue:v1:$id:$season';

  Future<ItemPage> episodeCatalogue(
    String id,
    String season, {
    bool force = false,
    bool Function()? allowed,
  }) async {
    final before = knownItems();
    var fetched = false;
    final page = await read(
      episodeCatalogueKey(id, season),
      () {
        fetched = true;
        return api.episodeCatalogue(
          id,
          season,
          allowed: () => current && !paused && allowed?.call() != false,
          spacing: spacing,
        );
      },
      force: force,
      allowed: allowed,
    );
    if (current && fetched) {
      await reconcileSnapshot(before, page, parent: id, season: season);
    }
    return page;
  }

  Future<MediaItem> detail(String id, {bool force = false}) async =>
      (await read(
        'detail:$id',
        () async => ItemPage([
          MediaItem({
            ...(await api.detail(id)).data,
            '_YingyuVideoMetadataV1': true,
            '_YingyuPeopleMetadataV1': true,
          }),
        ], 1),
        force:
            force ||
            peek(
                  'detail:$id',
                )?.items.firstOrNull?.data['_YingyuPeopleMetadataV1'] !=
                true,
      )).items.single;
  Future<ItemPage> seasons(String id) =>
      read('seasons:$id', () => api.seasons(id));
  Future<ItemPage> episodes(String id, String season, int start) => read(
    'episodes:$id:$season:$start',
    () => api.episodes(id, season, start: start),
  );
  static String browseKey(
    String? parent,
    String search,
    int start,
    String sort,
    bool? played,
    bool index,
  ) => jsonEncode(['browse', parent, search, start, sort, played, index]);
  Future<ItemPage> items({
    String? parent,
    String search = '',
    int start = 0,
    String sort = '',
    bool? played,
    bool index = false,
    bool force = false,
    bool Function()? allowed,
  }) => read(
    browseKey(parent, search, start, sort, played, index),
    () => api.browseItems(
      parent: parent,
      search: search,
      start: start,
      sort: sort,
      played: played,
      limit: index ? 200 : 48,
      minimal: index,
    ),
    force: force,
    allowed: allowed,
  );
  void invalidateProgress(String id) {
    for (final query in ['detail:$id', 'resume:0:18', 'resume:0:48']) {
      cache.records.remove(key(query));
    }
  }

  void invalidateResume() {
    resumeRevision++;
    _pending.removeWhere((query, _) => query.startsWith('resume:'));
    cache.records.removeWhere((stored, _) {
      final parts = jsonDecode(stored);
      return parts is List &&
          parts.length == 3 &&
          parts[0] == account.base.toString() &&
          parts[1] == account.userId &&
          parts[2] is String &&
          (parts[2] as String).startsWith('resume:');
    });
  }
}
