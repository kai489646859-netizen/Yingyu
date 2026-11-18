import 'dart:convert';

import '../playback/danmaku_preferences.dart';
import '../version.dart';
import 'browse_cache.dart';
import 'interface_preferences.dart';
import 'log_export.dart';
import 'store.dart';

class SettingsExport {
  static String snapshot(
    AppStore store,
    InterfacePreferences interface,
    BrowsePreferences browse,
  ) {
    final danmaku = DanmakuPreferences.read(store.prefs);
    final appearance = danmaku.appearance;
    // Export effective, global preferences by name. Account-specific settings,
    // private service URLs and raw preference values stay on the device.
    const json = JsonEncoder.withIndent('  ');
    final values = {
      'format': 'yingyu.settings',
      'schemaVersion': 1,
      'appVersion': appVersion,
      'appearance': {
        'theme': store.theme.name,
        'accent': store.accent.name,
        'posterActions': interface.posterActionMode.name,
        'libraryDisplay': interface.libraryDisplay.name,
        'reducedMotion': interface.reducedMotion,
      },
      'browse': {'sort': browse.sort, 'descending': browse.descending},
      'playback': {
        'nativeHdr': store.nativeHdr,
        'audioBalanceEnabled': store.audioBalanceEnabled,
        'audioBalance': store.audioBalance.name,
        'allowMobilePlayback': store.allowMobilePlayback,
        'autoNext': store.autoNext,
        'prepareNext': interface.prepareNext,
        'holdSpeed': store.holdSpeed,
      },
      'subtitles': {
        'automatic': store.autoSubtitles,
        'scale': store.subtitleScale,
        'automaticTranslation': store.translation.automatic,
        'translationWifiOnly': store.translation.wifiOnly,
      },
      'danmaku': {
        'enabled': danmaku.enabled,
        'automatic': danmaku.automatic,
        'featured': appearance.featured,
        'scroll': appearance.scroll,
        'top': appearance.top,
        'bottom': appearance.bottom,
        'adaptive': appearance.adaptive,
        'background': appearance.background,
        'opacity': appearance.opacity,
        'fontSize': appearance.fontSize,
        'area': appearance.area,
        'travelSeconds': appearance.travel,
        'delaySeconds': appearance.delay,
      },
      'cacheAndLoading': {
        'imageCacheGB': interface.cacheGB,
        'actorCacheGB': interface.actorCacheGB,
        'landscapeCacheGB': interface.landscapeCacheGB,
        'videoCacheGB': store.playbackCacheGB,
        'imageAutoCleanDays': interface.imageAutoCleanDays,
        'imageLoadSpeed': interface.imageLoadSpeed.name,
        'imageRequestLimit': interface.imageRequestLimit,
        'browseRefreshMinutes': browse.minutes,
      },
      'diagnosticLogging': store.log.enabled,
    };
    return '${json.convert(values)}\n';
  }

  static Future<bool> save(
    AppStore store,
    InterfacePreferences interface,
    BrowsePreferences browse,
  ) {
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    return LogFileExport.saveText(
      snapshot(store, interface, browse),
      'Yingyu-settings-$stamp.json',
      method: 'saveSettings',
    );
  }
}
