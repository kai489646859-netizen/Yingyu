import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' show ThemeMode;

import '../playback/audio_balance.dart';
import '../playback/cache_policy.dart';
import '../playback/danmaku_preferences.dart';
import 'appearance.dart';
import 'browse_cache.dart';
import 'image_loading.dart';
import 'interface_preferences.dart';
import 'log_export.dart';
import 'models.dart';
import 'store.dart';

class SettingsImport {
  SettingsImport._(this._changes);

  final List<(Future<void> Function(), Future<void> Function())> _changes;
  int get changeCount => _changes.length;

  static Future<Uint8List?> choose() =>
      LogFileExport.channel.invokeMethod<Uint8List>('openSettings');

  factory SettingsImport.parse(
    Uint8List bytes,
    AppStore store,
    InterfacePreferences interface,
    BrowsePreferences browse,
  ) {
    if (bytes.length > 64 * 1024) {
      throw const AppFailure('设置文件超过 64 KiB');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'yingyu.settings') {
      throw const AppFailure('请选择映屿导出的设置 JSON 文件');
    }
    if (decoded['schemaVersion'] != 1) {
      throw const AppFailure('此设置文件版本暂不支持');
    }

    Json section(String key) {
      if (!decoded.containsKey(key)) return {};
      final value = decoded[key];
      if (value is! Map<String, dynamic>) {
        throw const AppFailure('设置文件中的分组格式无效');
      }
      return value;
    }

    final changes = <(Future<void> Function(), Future<void> Function())>[];
    T read<T>(Json values, String key, T fallback, T? Function(Object?) parse) {
      if (!values.containsKey(key)) return fallback;
      final value = parse(values[key]);
      if (value == null) throw AppFailure('设置项 $key 的值无效');
      return value;
    }

    void add<T>(T previous, T value, Future<void> Function(T) write) {
      if (value != previous) {
        changes.add((() => write(value), () => write(previous)));
      }
    }

    bool? flag(Object? value) => value is bool ? value : null;
    int? Function(Object?) oneOf(Iterable<int> allowed) =>
        (value) => value is int && allowed.contains(value) ? value : null;
    T? Function(Object?) named<T extends Enum>(Iterable<T> allowed) =>
        (value) => allowed.where((entry) => entry.name == value).firstOrNull;
    double? Function(Object?) range(double min, double max) =>
        (value) =>
            value is num && value.isFinite && value >= min && value <= max
            ? value.toDouble()
            : null;
    void field<T>(
      Json values,
      String key,
      T previous,
      T? Function(Object?) parse,
      Future<void> Function(T) write,
    ) => add(previous, read(values, key, previous, parse), write);

    final appearance = section('appearance');
    field(
      appearance,
      'theme',
      store.theme,
      named(ThemeMode.values),
      store.setTheme,
    );
    field(
      appearance,
      'accent',
      store.accent,
      named(AppAccent.available),
      store.setAccent,
    );
    field(
      appearance,
      'posterActions',
      interface.posterActionMode,
      named(PosterActionMode.values),
      interface.setPosterActionMode,
    );
    field(
      appearance,
      'libraryDisplay',
      interface.libraryDisplay,
      named(LibraryDisplay.values),
      interface.setLibraryDisplay,
    );
    field(
      appearance,
      'reducedMotion',
      interface.reducedMotion,
      flag,
      interface.setReducedMotion,
    );

    final order = section('browse');
    final oldOrder = (browse.sort, browse.descending);
    add(oldOrder, (
      read(
        order,
        'sort',
        oldOrder.$1,
        (value) => value is String && BrowsePreferences.sorts.contains(value)
            ? value
            : null,
      ),
      read(order, 'descending', oldOrder.$2, flag),
    ), (value) => browse.setSort(value.$1, descending: value.$2));

    final playback = section('playback');
    field(playback, 'nativeHdr', store.nativeHdr, flag, store.setNativeHdr);
    field(
      playback,
      'audioBalanceEnabled',
      store.audioBalanceEnabled,
      flag,
      store.setAudioBalanceEnabled,
    );
    field(
      playback,
      'audioBalance',
      store.audioBalance,
      named(AudioBalance.values),
      store.setAudioBalance,
    );
    field(
      playback,
      'allowMobilePlayback',
      store.allowMobilePlayback,
      flag,
      store.setAllowMobilePlayback,
    );
    field(playback, 'autoNext', store.autoNext, flag, store.setAutoNext);
    field(
      playback,
      'prepareNext',
      interface.prepareNext,
      flag,
      interface.setPrepareNext,
    );
    field(
      playback,
      'holdSpeed',
      store.holdSpeed,
      oneOf([2, 3]),
      store.setHoldSpeed,
    );

    final subtitles = section('subtitles');
    field(
      subtitles,
      'automatic',
      store.autoSubtitles,
      flag,
      store.setAutoSubtitles,
    );
    field(
      subtitles,
      'scale',
      store.subtitleScale,
      range(.6, 2),
      store.setSubtitleScale,
    );
    field(
      subtitles,
      'automaticTranslation',
      store.translation.automatic,
      flag,
      store.translation.setAutomatic,
    );
    field(
      subtitles,
      'translationWifiOnly',
      store.translation.wifiOnly,
      flag,
      store.translation.setWifiOnly,
    );

    final danmaku = section('danmaku');
    final current = DanmakuPreferences.read(store.prefs);
    final look = current.appearance;
    final updated = current.copyWith(
      enabled: read(danmaku, 'enabled', current.enabled, flag),
      automatic: read(danmaku, 'automatic', current.automatic, flag),
      appearance: look.update(
        featured: read(danmaku, 'featured', look.featured, flag),
        scroll: read(danmaku, 'scroll', look.scroll, flag),
        top: read(danmaku, 'top', look.top, flag),
        bottom: read(danmaku, 'bottom', look.bottom, flag),
        adaptive: read(danmaku, 'adaptive', look.adaptive, flag),
        background: read(danmaku, 'background', look.background, flag),
        opacity: read(danmaku, 'opacity', look.opacity, range(.15, 1)),
        fontSize: read(danmaku, 'fontSize', look.fontSize, range(14, 40)),
        area: read(danmaku, 'area', look.area, range(.2, 1)),
        travel: read(danmaku, 'travelSeconds', look.travel, range(4, 20)),
        delay: read(danmaku, 'delaySeconds', look.delay, range(-3600, 3600)),
      ),
    );
    if (updated.appearance != look ||
        updated.enabled != current.enabled ||
        updated.automatic != current.automatic) {
      Future<void> write(DanmakuPreferences value) async {
        if (!await value.save(store.prefs)) throw const AppFailure('弹幕设置保存失败');
      }

      add(current, updated, write);
    }

    final cache = section('cacheAndLoading');
    field(
      cache,
      'imageCacheGB',
      interface.cacheGB,
      oneOf([1, 5, 10]),
      interface.setCacheGB,
    );
    field(
      cache,
      'actorCacheGB',
      interface.actorCacheGB,
      oneOf([1, 3, 5]),
      interface.setActorCacheGB,
    );
    field(
      cache,
      'landscapeCacheGB',
      interface.landscapeCacheGB,
      oneOf([1, 3, 5]),
      interface.setLandscapeCacheGB,
    );
    field(
      cache,
      'videoCacheGB',
      store.playbackCacheGB,
      oneOf(playbackCacheChoices.keys),
      store.setPlaybackCacheGB,
    );
    field(
      cache,
      'imageAutoCleanDays',
      interface.imageAutoCleanDays,
      oneOf(InterfacePreferences.imageAutoCleanChoices.keys),
      interface.setImageAutoCleanDays,
    );
    field(
      cache,
      'imageLoadSpeed',
      interface.imageLoadSpeed,
      named(ImageLoadSpeed.values),
      interface.setImageLoadSpeed,
    );
    field(
      cache,
      'imageRequestLimit',
      interface.imageRequestLimit,
      oneOf(InterfacePreferences.imageRequestLimits),
      interface.setImageRequestLimit,
    );
    field(
      cache,
      'browseRefreshMinutes',
      browse.minutes,
      oneOf([5, 15, 30]),
      browse.setMinutes,
    );
    field(
      decoded,
      'diagnosticLogging',
      store.log.enabled,
      flag,
      (value) => store.log.setEnabled(value, requireSaved: true),
    );
    return SettingsImport._(changes);
  }

  Future<void> apply() async {
    final restore = <Future<void> Function()>[];
    try {
      for (final (write, undo) in _changes) {
        restore.add(undo);
        await write();
      }
    } catch (_) {
      var restored = true;
      for (final undo in restore.reversed) {
        try {
          await undo();
        } catch (_) {
          restored = false;
        }
      }
      throw AppFailure(restored ? '导入保存失败，已恢复原设置' : '导入保存失败，部分设置未能恢复');
    }
  }
}
