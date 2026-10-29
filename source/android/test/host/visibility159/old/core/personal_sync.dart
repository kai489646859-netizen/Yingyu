import 'dart:async';
import 'package:flutter/foundation.dart';
import 'emby.dart';
import 'models.dart';
import 'personal_library.dart';
import 'store.dart';

enum PersonalList { favorites, played, unplayed, likes, dislikes }

extension PersonalListInfo on PersonalList {
  String get label => ['收藏', '已看', '未看', '喜欢', '不喜欢'][index];
  String get filter =>
      ['IsFavorite', 'IsPlayed', 'IsUnplayed', 'Likes', 'Dislikes'][index];
}

/// One current-account coordinator. Mutations are explicit and serial; failures
/// remain visible and never become fake offline acknowledgements.
class PersonalSync extends ChangeNotifier {
  PersonalSync(
    this.api,
    this.library, {
    this.store,
    this.waitForPlaybackSync,
    this.onChanged,
    this.onWatched,
  }) : account = api.session!,
       transport = api.forAccount(api.session);
  final EmbyClient api, transport;
  final Session account;
  final PersonalLibrary library;
  final AppStore? store;
  final Future<void> Function()? waitForPlaybackSync;
  final void Function(MediaItem)? onChanged;
  final Future<void> Function(MediaItem)? onWatched;
  bool busy = false, _disposed = false;
  int revision = 0;
  MediaItem? changedItem;
  final Map<String, MediaItem> observed = {};
  final Map<String, bool?> ratings = {};
  bool get current => !_disposed && identical(api.session, account);

  void check() {
    if (!current) throw const AppFailure('账号已切换，请重新打开');
    if (api.backgroundWork.paused) throw const AppFailure('当前操作已暂停，请稍后重试');
  }

  Future<T> exclusive<T>(Future<T> Function() action) async {
    check();
    if (busy) throw const AppFailure('正在同步，请稍后重试');
    busy = true;
    notifyListeners();
    try {
      // A pending resume repair can contain the pre-edit favorite/rating data.
      // Drain it before any personal edit; the owner pauses new retries while
      // busy. Playback state and its original comparison policy stay intact.
      await waitForPlaybackSync?.call();
      check();
      return await action();
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  MediaItem latest(MediaItem item) => observed[item.id] ?? item;
  bool favorite(MediaItem item) =>
      object(latest(item).data['UserData'])['IsFavorite'] == true ||
      library.unsyncedFavorites(account).any((saved) => saved.id == item.id);

  MediaItem publish(MediaItem item, Json data) {
    check();
    item = latest(item);
    final saved = MediaItem({
      ...item.data,
      'UserData': {...object(item.data['UserData']), ...data},
    });
    observed[item.id] = saved;
    changedItem = saved;
    revision++;
    onChanged?.call(saved);
    notifyListeners();
    return saved;
  }

  Future<Json> verified(
    MediaItem item,
    Json data,
    String field,
    bool expected,
  ) async {
    check();
    if (!data.containsKey(field)) {
      data = object(
        (await api.backgroundWork.run(
          () => transport.detail(item.id),
        )).data['UserData'],
      );
      check();
    }
    if (data[field] != expected) throw const AppFailure('Emby 尚未确认修改，请刷新后重试');
    return data;
  }

  Future<void> setFavorite(MediaItem item, bool value) => exclusive(() async {
    if (item.id.isEmpty) throw const AppFailure('资源编号缺失');
    final data = await verified(
      item,
      await transport.setFavorite(item.id, value),
      'IsFavorite',
      value,
    );
    final saved = publish(item, data);
    try {
      await library.acknowledgeFavorite(account, saved, value);
    } catch (e) {
      throw AppFailure('Emby 已更新，本机收藏保存失败：${safeError(e)}');
    }
  });

  Future<ItemPage> page(PersonalList list, {int start = 0}) async {
    check();
    final before = revision;
    final page = await api.backgroundWork.run(
      () => transport.personalItems(list.filter, start: start),
    );
    check();
    if (revision == before) {
      for (final item in page.items) {
        observed[item.id] = item;
        if (list == PersonalList.likes || list == PersonalList.dislikes) {
          ratings[item.id] = list == PersonalList.likes;
        }
      }
    }
    return page;
  }

  Future<void> refreshFavorites({bool Function()? allowed}) =>
      exclusive(() async {
        final gathered = <String, MediaItem>{};
        var start = 0;
        while (true) {
          check();
          if (allowed?.call() == false) return;
          final page = await this.page(PersonalList.favorites, start: start);
          if (allowed?.call() == false) return;
          final before = gathered.length;
          for (final item in page.items) {
            gathered[item.id] = item;
          }
          start += page.items.length;
          if (start >= page.total) break;
          if (gathered.length == before) {
            throw const AppFailure('收藏列表返回不完整，原有收藏已保留');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        check();
        await library.reconcileFavorites(account, gathered.values.toList());
        check();
        for (final entry in observed.entries.toList()) {
          if (!gathered.containsKey(entry.key) &&
              !library.contains(account, SavedList.favorites, entry.key)) {
            observed[entry.key] = MediaItem({
              ...entry.value.data,
              'UserData': {
                ...object(entry.value.data['UserData']),
                'IsFavorite': false,
              },
            });
          }
        }
        for (final item in gathered.values) {
          observed[item.id] = item;
        }
        // Only opening/refreshing Favorites initiates the one-time migration.
        for (final item in library.unsyncedFavorites(account)) {
          if (allowed?.call() == false) return;
          check();
          final data = await verified(
            item,
            await transport.setFavorite(item.id, true),
            'IsFavorite',
            true,
          );
          await library.acknowledgeFavorite(account, publish(item, data), true);
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      });

  Future<bool?> readRating(String id) async {
    // Current DTO documentation omits Likes. Ask the documented filters rather
    // than guessing how a numeric Rating maps to like/dislike.
    check();
    final liked = await api.backgroundWork.run(
      () => transport.personalItems('Likes', id: id, limit: 1),
    );
    check();
    final disliked = await api.backgroundWork.run(
      () => transport.personalItems('Dislikes', id: id, limit: 1),
    );
    check();
    final yes = liked.items.any((v) => v.id == id),
        no = disliked.items.any((v) => v.id == id);
    if (yes && no) throw const AppFailure('Emby 返回了矛盾的喜好状态，请稍后重试');
    return yes
        ? true
        : no
        ? false
        : null;
  }

  Future<MediaItem> refreshStatus(MediaItem item) => exclusive(() async {
    final saved = await api.backgroundWork.run(() => transport.detail(item.id));
    check();
    ratings[item.id] = await readRating(item.id);
    return publish(saved, object(saved.data['UserData']));
  });

  Future<void> setRating(MediaItem item, bool? likes) => exclusive(() async {
    if (item.id.isEmpty) throw const AppFailure('资源编号缺失');
    final data = await transport.setPersonalRating(item.id, likes);
    check();
    final actual = await readRating(item.id);
    if (actual != likes) throw const AppFailure('Emby 尚未确认喜好，请刷新后重试');
    ratings[item.id] = actual;
    publish(item, data);
  });

  Future<void> setPlayed(MediaItem item, bool value) => exclusive(() async {
    if (item.id.isEmpty) throw const AppFailure('资源编号缺失');
    if (!const ['Movie', 'Episode', 'Video'].contains(item.type)) {
      throw const AppFailure('请在具体影片或分集上修改观看状态');
    }
    if (store?.localProgress(account, item.id) != null ||
        store?.completions.pending(account, item.id) == true) {
      throw const AppFailure('此片有待同步观看记录，请先同步后再修改已看状态');
    }
    final data = await verified(
      item,
      await transport.setPersonalPlayed(item.id, value),
      'Played',
      value,
    );
    final saved = publish(item, data);
    await store?.completions.forgetConfirmed(account, item.id);
    await store?.recordWatchDisplay(account, saved, Duration.zero, false);
    check();
    await onWatched?.call(saved);
  });

  @override
  void dispose() {
    _disposed = true;
    transport.close();
    super.dispose();
  }
}
