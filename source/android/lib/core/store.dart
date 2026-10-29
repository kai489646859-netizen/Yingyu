import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'emby.dart';
import 'models.dart';
import 'log.dart';
import '../playback/tracks.dart';
import '../playback/audio_balance.dart';
import 'progress.dart';
import 'appearance.dart';
import 'accounts.dart';
import 'browse_cache.dart';
import 'account_display.dart';
import 'account_avatars.dart';
import 'personal_library.dart';
import 'offline_translation.dart';
import 'completion_sync.dart';
import 'home_order.dart';
import 'image_references.dart';
import '../playback/byte_cache.dart';
import '../playback/cache_policy.dart';
import '../playback/subtitle_position_memory.dart';

class AppStore extends ChangeNotifier {
  AppStore(
    this.prefs, {
    DiagnosticLog? log,
    ImageReferences? images,
    PlaybackByteCache? videoCache,
  }) : log = log ?? DiagnosticLog(prefs: prefs),
       images = images ?? ImageReferences(),
       videoCache = videoCache ?? PlaybackByteCache();
  final ImageReferences images;
  final SharedPreferences prefs;
  final DiagnosticLog log;
  late final accounts = AccountStore(prefs);
  late final browseCache = BrowseCache(prefs, images: images);
  late final accountDisplays = AccountDisplays(prefs);
  AccountAvatars? _avatars;
  AccountAvatars get avatars => _avatars ??= AccountAvatars(prefs);
  late final personal = PersonalLibrary(prefs);
  late final translation = OfflineTranslation(prefs, log: log);
  late final completions = CompletionSync(
    prefs,
    log,
    removals: homeOrder.removals,
  );
  late final homeOrder = HomeOrder(prefs);
  final PlaybackByteCache videoCache;
  late final subtitlePositions = SubtitlePositionMemory(prefs);
  bool get nativeHdr => prefs.getBool('yingyu.playback.nativeHdr.v1') ?? false;
  AudioBalance get audioBalance =>
      AudioBalance.values
          .where(
            (v) => v.name == prefs.getString('yingyu.playback.audioBalance.v1'),
          )
          .firstOrNull ??
      AudioBalance.original;
  bool get audioBalanceEnabled =>
      prefs.getBool('yingyu.playback.audioBalanceEnabled.v1') ?? false;
  Future<void> setAudioBalanceEnabled(bool value) async {
    if (!await prefs.setBool('yingyu.playback.audioBalanceEnabled.v1', value)) {
      throw const AppFailure('音量均衡开关保存失败');
    }
    notifyListeners();
  }

  Future<void> setAudioBalance(AudioBalance value) async {
    if (!await prefs.setString('yingyu.playback.audioBalance.v1', value.name)) {
      throw const AppFailure('音量均衡设置保存失败');
    }
    notifyListeners();
  }

  Future<void> setNativeHdr(bool value) async {
    if (!await prefs.setBool('yingyu.playback.nativeHdr.v1', value)) {
      throw const AppFailure('HDR 输出设置保存失败');
    }
    notifyListeners();
  }

  int get playbackCacheGB {
    final value = prefs.getInt('yingyu.playback.cacheGB.v1') ?? 0;
    return playbackCacheChoices.containsKey(value) ? value : 0;
  }

  Future<void> setPlaybackCacheGB(int value) async {
    if (!playbackCacheChoices.containsKey(value)) return;
    if (!await prefs.setInt('yingyu.playback.cacheGB.v1', value)) {
      throw const AppFailure('播放缓存设置保存失败');
    }
    notifyListeners();
    await videoCache.configure(value < 0 ? -1 : value * playbackGiB);
  }

  bool get allowMobilePlayback =>
      prefs.getBool('yingyu.playback.mobile.v1') ?? false;
  Future<void> setAllowMobilePlayback(bool value) async {
    if (!await prefs.setBool('yingyu.playback.mobile.v1', value)) {
      throw const AppFailure('流量播放设置保存失败');
    }
    notifyListeners();
  }

  bool get autoNext => prefs.getBool('yingyu.playback.autoNext.v1') ?? true;
  Future<void> setAutoNext(bool value) async {
    if (!await prefs.setBool('yingyu.playback.autoNext.v1', value)) {
      throw const AppFailure('自动下一集设置保存失败');
    }
    notifyListeners();
  }

  Future<void> saveAccountDisplay(
    Session session,
    String alias,
    int color,
  ) async {
    await accountDisplays.save(session, alias, color);
    notifyListeners();
  }

  int get holdSpeed =>
      prefs.getInt('yingyu.playback.holdSpeed.v1') == 2 ? 2 : 3;
  Future<void> setHoldSpeed(int value) async {
    if (value != 2 && value != 3) return;
    if (!await prefs.setInt('yingyu.playback.holdSpeed.v1', value)) {
      throw const AppFailure('长按倍速保存失败');
    }
    notifyListeners();
  }

  // Retired liquid-glass IDs remain readable, but upgrades always use the
  // traditional presentation. Theme colors and other preferences are intact.
  VisualStyle get visualStyle => VisualStyle.traditional;

  Future<void> setVisualStyle(VisualStyle value) async {
    if (!await prefs.setString(
      'yingyu.visualStyle.v1',
      VisualStyle.traditional.name,
    )) {
      throw const AppFailure('外观风格保存失败');
    }
    notifyListeners();
  }

  AppAccent get accent {
    final saved = prefs.getString('yingyu.accent.v1');
    if (saved == 'rose') return AppAccent.blush;
    return AppAccent.available
            .where((value) => value.name == saved)
            .firstOrNull ??
        AppAccent.lilac;
  }

  Future<void> setAccent(AppAccent value) async {
    if (!AppAccent.available.contains(value)) value = AppAccent.lilac;
    if (!await prefs.setString('yingyu.accent.v1', value.name)) {
      throw const AppFailure('主题色保存失败');
    }
    notifyListeners();
  }

  double get subtitleScale =>
      (prefs.getDouble('yingyu.subtitles.scale.v1') ?? 1).clamp(.6, 2);
  Future<void> setSubtitleScale(double value) async {
    if (!value.isFinite || value < .6 || value > 2) {
      throw const AppFailure('字幕大小超出支持范围');
    }
    if (!await prefs.setDouble('yingyu.subtitles.scale.v1', value)) {
      throw const AppFailure('字幕大小保存失败');
    }
    notifyListeners();
  }

  bool get autoSubtitles => prefs.getBool('yingyu.subtitles.auto.v1') ?? true;
  Future<void> setAutoSubtitles(bool value) async {
    if (!await prefs.setBool('yingyu.subtitles.auto.v1', value)) {
      throw const AppFailure('字幕偏好保存失败');
    }
    notifyListeners();
  }

  String _trackKey(Session account, String scope, bool subtitle) => jsonEncode([
    account.serverId.isEmpty
        ? account.base.toString()
        : 'server:${account.serverId}',
    account.userId,
    scope,
    subtitle,
  ]);
  Json _trackMemory() {
    try {
      return object(jsonDecode(prefs.getString('yingyu.tracks.v1') ?? '{}'));
    } catch (_) {
      return {};
    }
  }

  TrackChoice? trackChoice(Session account, String scope, bool subtitle) {
    final memory = _trackMemory();
    final data = object(
      memory[_trackKey(account, scope, subtitle)] ??
          memory[jsonEncode([
            account.base.toString(),
            account.userId,
            scope,
            subtitle,
          ])],
    );
    return data.isEmpty ? null : TrackChoice(data);
  }

  Future<void> saveTrackChoice(
    Session account,
    List<String> scopes,
    bool subtitle,
    TrackChoice? choice,
  ) async {
    final memory = _trackMemory();
    for (final scope in scopes) {
      final key = _trackKey(account, scope, subtitle);
      memory.remove(key);
      memory.remove(
        jsonEncode([account.base.toString(), account.userId, scope, subtitle]),
      );
      if (choice != null) memory[key] = choice.data;
    }
    // Explicit user choices are durable preferences, not an evictable cache.
    if (!await prefs.setString('yingyu.tracks.v1', jsonEncode(memory))) {
      throw const AppFailure('轨道已经切换，但选择记忆保存失败');
    }
  }

  ThemeMode get theme => switch (prefs.getString('yingyu.theme.v1')) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
  Future<void> setTheme(ThemeMode mode) async {
    await prefs.setString('yingyu.theme.v1', mode.name);
    notifyListeners();
  }

  Future<String> deviceId() async {
    final saved = prefs.getString('yingyu.device.v1');
    if (saved != null) return saved;
    final custom = prefs.getString('media_server_device_id_custom_v1');
    final generated = prefs.getString('media_server_device_id_generated_v1');
    final value = (custom?.trim().isNotEmpty ?? false)
        ? custom!.trim()
        : generated != null
        ? 'Yingyu-Android-$generated'
        : 'Yingyu-Android-${newId()}';
    await prefs.setString('yingyu.device.v1', value);
    return value;
  }

  Future<Session?> loadSession() async {
    await accounts.load(deviceId);
    return accounts.selected?.session;
  }

  Future<void> saveSession(Session session) async {
    await accounts.load(deviceId);
    await accounts.saveAndSelect(session);
  }

  Future<void> clearSession() async {
    await accounts.load(deviceId);
    final current = accounts.selected;
    if (current != null) await accounts.remove(current.id);
  }

  String _progressKey(Session session, String itemId) =>
      'yingyu.position.${Uri.encodeComponent(session.base.toString())}.${session.userId}.$itemId';
  Duration? localProgress(Session session, String itemId) {
    final value = prefs.getInt(_progressKey(session, itemId));
    return value == null ? null : Duration(milliseconds: value);
  }

  String _watchDisplayKey(Session account) =>
      'yingyu.watch-display.v1.${accountKey(account)}';
  Json _watchDisplay(Session account) {
    try {
      return object(
        jsonDecode(prefs.getString(_watchDisplayKey(account)) ?? '{}'),
      );
    } catch (_) {
      return {};
    } // Optional display evidence; never alters progress.
  }

  bool rewatchObserved(Session account, MediaItem item) =>
      object(_watchDisplay(account)[item.id])['server'] ==
      progressFingerprint(item);
  bool restartObserved(Session account, MediaItem item) {
    final saved = object(_watchDisplay(account)[item.id]);
    if (saved['restart'] != true) return false;
    if (saved['server'] == progressFingerprint(item)) return true;
    // A home card projects the pending checkpoint onto server metadata. At
    // zero that projection must still identify the same server observation,
    // rather than discarding an intentional restart before it can be synced.
    if (saved['position'] != 0 ||
        localProgress(account, item.id) != Duration.zero ||
        item.resume != Duration.zero) {
      return false;
    }
    try {
      final baseline = jsonDecode(saved['server'] as String);
      if (baseline is! List ||
          baseline.length != 4 ||
          baseline.first is! int ||
          (baseline.first as int) < 0) {
        return false;
      }
      return saved['server'] ==
          progressFingerprint(
            MediaItem({
              ...item.data,
              'UserData': {
                ...object(item.data['UserData']),
                'PlaybackPositionTicks': ticks(
                  Duration(milliseconds: baseline.first as int),
                ),
              },
            }),
          );
    } catch (_) {
      return false;
    }
  }

  String watchDisplaySnapshot(Session account, String id) =>
      jsonEncode(object(_watchDisplay(account)[id]));
  Future<void> _watchDisplayTail = Future.value();
  Future<void> recordWatchDisplay(
    Session account,
    MediaItem item,
    Duration position,
    bool rewatch, {
    String? expected,
    bool restart = false,
    bool Function()? allowed,
  }) {
    final result = _watchDisplayTail.then((_) async {
      if (allowed?.call() == false) return;
      final data = _watchDisplay(account);
      if (expected != null && jsonEncode(object(data[item.id])) != expected) {
        return;
      }
      data.remove(item.id);
      if (rewatch) {
        data[item.id] = {
          'position': position.inMilliseconds,
          'server': progressFingerprint(item),
          if (restart) 'restart': true,
        };
      }
      while (data.length > 18) {
        data.remove(data.keys.first);
      }
      if (!await prefs.setString(_watchDisplayKey(account), jsonEncode(data))) {
        throw const AppFailure('重看显示记录保存失败，观看进度仍按原流程保存');
      }
    });
    _watchDisplayTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _acknowledgeWatchDisplay(
    Session account,
    MediaItem item,
    Duration expected, {
    String? evidence,
    bool Function()? allowed,
  }) async {
    if (allowed?.call() == false) return;
    final saved = object(_watchDisplay(account)[item.id]);
    if ((evidence == null || jsonEncode(saved) == evidence) &&
        saved['position'] == expected.inMilliseconds &&
        progressMatches(item.resume, expected) &&
        saved['server'] != progressFingerprint(item)) {
      await recordWatchDisplay(
        account,
        item,
        item.resume,
        saved['restart'] == true ||
            (object(item.data['UserData'])['Played'] == true &&
                item.resume > Duration.zero),
        expected: jsonEncode(saved),
        restart: saved['restart'] == true,
        allowed: allowed,
      );
    }
  }

  Future<void> saveProgress(
    Session session,
    String id,
    Duration position, {
    MediaItem? serverBaseline,
    bool keepZeroDisplay = false,
    bool completed = false,
    bool Function()? allowed,
  }) async {
    if (allowed?.call() == false) return;
    final key = _progressKey(session, id);
    final revision = (_progressWrites[key] ?? 0) + 1;
    _progressWrites[key] = revision;
    bool current() =>
        allowed?.call() != false && _progressWrites[key] == revision;
    String? protectionWarning;
    if (!completed) {
      try {
        await completions.supersede(session, id, allowed: current);
      } catch (error) {
        // Keep saving the real checkpoint when only the completion-protection
        // metadata failed. Its persistence failure must still reach the UI.
        protectionWarning = safeError(error);
      }
      if (!current()) return;
    }
    try {
      if (!await prefs.setInt(key, position.inMilliseconds)) {
        throw const AppFailure('本机进度保存失败');
      }
      if (!current()) return;
      if (serverBaseline != null &&
          !await prefs.setString(
            '$key.baseline',
            progressFingerprint(serverBaseline),
          )) {
        throw const AppFailure('本机进度核对信息保存失败');
      }
      if (!current()) return;
      final before = object(_watchDisplay(session)[id]);
      if (keepZeroDisplay && serverBaseline != null) {
        await recordWatchDisplay(
          session,
          serverBaseline,
          position,
          true,
          expected: jsonEncode(before),
          restart: true,
          allowed: current,
        );
      } else if (before['restart'] == true) {
        await recordWatchDisplay(
          session,
          MediaItem({'Id': id}),
          position,
          false,
          expected: jsonEncode(before),
          allowed: current,
        );
      }
    } catch (error) {
      if (protectionWarning != null) {
        throw AppFailure('$protectionWarning；${safeError(error)}');
      }
      rethrow;
    }
    if (protectionWarning != null) throw AppFailure(protectionWarning);
  }

  final Map<String, int> _progressWrites = {};

  ({Duration position, String reason}) resume(
    Session account,
    MediaItem server,
  ) => resolveResume(
    server,
    localProgress(account, server.id),
    prefs.getString('${_progressKey(account, server.id)}.baseline'),
  );

  Future<void> observeProgress(
    Session account,
    MediaItem server,
    Duration expected, {
    bool Function()? allowed,
  }) async {
    if (allowed?.call() == false) return;
    final key = _progressKey(account, server.id);
    final revision = _progressWrites[key];
    final evidence = watchDisplaySnapshot(account, server.id);
    bool current() =>
        allowed?.call() != false && _progressWrites[key] == revision;
    if (localProgress(account, server.id) == expected) {
      if (!await prefs.setString(
        '${_progressKey(account, server.id)}.baseline',
        progressFingerprint(server),
      )) {
        throw const AppFailure('本机进度核对信息保存失败');
      }
    }
    if (!current()) return;
    await _acknowledgeWatchDisplay(
      account,
      server,
      expected,
      evidence: evidence,
      allowed: current,
    );
  }

  Future<void> confirmProgress(
    Session session,
    String id,
    Duration position, {
    bool Function()? allowed,
  }) async {
    if (allowed?.call() == false) return;
    final key = _progressKey(session, id);
    final revision = _progressWrites[key];
    bool current() =>
        allowed?.call() != false && _progressWrites[key] == revision;
    if (prefs.getInt(key) == position.inMilliseconds) {
      final baseline = prefs.getString('$key.baseline');
      if (!await prefs.remove(key)) {
        throw const AppFailure('Emby 已确认进度，但本机待同步记录清理失败');
      }
      // Platform persistence yields. A new playback can already have written
      // another checkpoint; never remove its server-observation baseline.
      if (current() &&
          prefs.getInt(key) == null &&
          prefs.getString('$key.baseline') == baseline &&
          !await prefs.remove('$key.baseline')) {
        throw const AppFailure('本机进度核对信息清理失败');
      }
    }
  }

  Future<void>? _retryingProgress;
  final Map<String, String> _progressRetryAfter = {};
  Future<void> retryPendingProgress(
    EmbyClient api,
    Session account, {
    String? exclude,
    bool Function()? allowed,
  }) => _retryingProgress ??=
      _retryPendingProgress(
        api,
        account,
        exclude: exclude,
        allowed: allowed,
      ).whenComplete(() {
        _retryingProgress = null;
      });

  Future<void> _retryPendingProgress(
    EmbyClient api,
    Session account, {
    String? exclude,
    bool Function()? allowed,
  }) async {
    final prefix = _progressKey(account, '');
    final keys =
        prefs
            .getKeys()
            .where((k) => k.startsWith(prefix) && prefs.get(k) is int)
            .toList()
          ..sort();
    final after = _progressRetryAfter[prefix];
    final ordered = after == null
        ? keys
        : [
            ...keys.where((k) => k.compareTo(after) > 0),
            ...keys.where((k) => k.compareTo(after) <= 0),
          ];
    var tried = 0;
    bool current() => api.session == account && allowed?.call() != false;
    for (final key in ordered) {
      if (!current() || tried >= 2) return;
      _progressRetryAfter[prefix] = key;
      final id = key.substring(prefix.length);
      if (id == exclude || id.isEmpty) continue;
      final pending = localProgress(account, id);
      if (pending == null) continue;
      final checkpointRevision = _progressWrites[key];
      final evidence = watchDisplaySnapshot(account, id);
      bool sameCheckpoint() =>
          _progressWrites[key] == checkpointRevision &&
          localProgress(account, id) == pending;
      final removals = homeOrder.removals;
      if (!removals.progressAllowed(account, id, log)) continue;
      var readingDetail = false;
      var readRevision = removals.progressRevision(account, id);
      bool eligible() =>
          current() && removals.progressAllowed(account, id, log);
      Future<MediaItem> read() {
        readingDetail = true;
        readRevision = removals.progressRevision(account, id);
        return api.detail(id, requestTimeout: const Duration(seconds: 3));
      }

      try {
        if (completions.pending(account, id)) continue;
        tried++;
        var saved = await read();
        readingDetail = false;
        if (!current() || !sameCheckpoint()) return;
        if (!eligible()) continue;
        if (saved.id != id) throw const AppFailure('进度核对资源编号不一致，记录保留');
        if (!removals.progressAllowed(account, id, log, item: saved)) continue;
        bool matches() => progressMatches(saved.resume, pending);
        if (!matches()) {
          final baseline = prefs.getString('$key.baseline');
          if (baseline != progressFingerprint(saved)) {
            log.add(
              LogArea.progress,
              'Emby 记录已改变，保留本机待同步位置以免覆盖其他设备的新记录',
              level: LogLevel.warning,
            );
            continue;
          }
          await api.saveResume(
            saved,
            pending,
            requestTimeout: const Duration(seconds: 3),
          );
          if (!eligible() || !sameCheckpoint()) return;
          saved = await read();
          readingDetail = false;
          if (!current() || !sameCheckpoint()) return;
          if (!eligible()) continue;
          if (saved.id != id) throw const AppFailure('进度核对资源编号不一致，记录保留');
        }
        if (matches()) {
          await confirmProgress(
            account,
            id,
            pending,
            allowed: () => eligible() && sameCheckpoint(),
          );
          await _acknowledgeWatchDisplay(
            account,
            saved,
            pending,
            evidence: evidence,
            allowed: () =>
                eligible() && _progressWrites[key] == checkpointRevision,
          );
          log.add(
            LogArea.progress,
            '分集进度补传已回读确认；位置=${pending.inMilliseconds} ms',
          );
        } else {
          log.add(
            LogArea.progress,
            '分集进度补传尚未确认，本机记录保留',
            level: LogLevel.warning,
          );
        }
      } catch (e) {
        if (!current()) return;
        if (readingDetail &&
            e is AppFailure &&
            (e.status == 404 || e.status == 410)) {
          await removals.pauseProgress(
            account,
            id,
            readRevision,
            log,
            e.status!,
          );
          continue;
        }
        log.add(
          LogArea.progress,
          '分集进度补传失败：${safeError(e)}；本机记录保留',
          level: LogLevel.warning,
        );
        if (api.connection.hasProblem) return;
      }
    }
  }

  String _discKey(Session account, String item, String source) =>
      'yingyu.disc.playlist.v1.${base64Url.encode(utf8.encode(jsonEncode([account.base.toString(), account.userId, item, source])))}';
  int? discPlaylist(Session account, String item, String source) =>
      prefs.getInt(_discKey(account, item, source));
  DiscKind? discKind(Session account, String item, String source) {
    final value = prefs.getInt('${_discKey(account, item, source)}.kind');
    return value == 1
        ? DiscKind.iso
        : value == 2
        ? DiscKind.blurayFolder
        : null;
  }

  Future<void> saveDiscKind(
    Session account,
    String item,
    String source,
    DiscKind? kind,
  ) async {
    if (!await prefs.setInt(
      '${_discKey(account, item, source)}.kind',
      kind?.index ?? 0,
    )) {
      throw const AppFailure('无法保存原盘读取方式');
    }
  }

  Future<void> saveDiscPlaylist(
    Session account,
    String item,
    String source,
    int playlist,
  ) async {
    if (playlist < 0 || playlist > 99999) throw const AppFailure('原盘播放列表无效');
    if (!await prefs.setInt(_discKey(account, item, source), playlist)) {
      throw const AppFailure('无法保存原盘标题选择');
    }
  }

  @override
  void dispose() {
    _avatars?.dispose();
    super.dispose();
  }
}
