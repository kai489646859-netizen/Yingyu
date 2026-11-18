import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

typedef DanmakuAppearance = ({
  bool featured,
  bool scroll,
  bool top,
  bool bottom,
  bool adaptive,
  bool background,
  double opacity,
  double fontSize,
  double area,
  double travel,
  double delay,
});

const defaultDanmakuAppearance = (
  featured: false,
  scroll: true,
  top: true,
  bottom: true,
  adaptive: true,
  background: false,
  opacity: .8,
  fontSize: 24.0,
  area: .5,
  travel: 9.0,
  delay: 0.0,
);

const danmakuSourceNames = ['哔哩哔哩', '腾讯视频', '爱奇艺', '芒果 TV', '兼容弹幕服务', '本地 XML'];

class DanmakuPreferences {
  const DanmakuPreferences({
    this.enabled = true,
    this.automatic = true,
    this.compatible = '',
    this.appearance = defaultDanmakuAppearance,
    this.hidden = const {},
    this.delays = const {},
  });

  final bool enabled, automatic;
  final String compatible;
  final DanmakuAppearance appearance;
  final Set<String> hidden;
  final Map<String, double> delays;

  DanmakuPreferences configure(String source, {bool? enabled, double? delay}) {
    if (!danmakuSourceNames.contains(source)) return this;
    final disabled = {...hidden};
    final offsets = {...delays};
    if (enabled != null) {
      if (enabled) {
        disabled.remove(source);
      } else {
        disabled.add(source);
      }
    }
    if (delay != null && delay.isFinite) {
      if (delay == 0) {
        offsets.remove(source);
      } else {
        offsets[source] = delay.clamp(-3600, 3600);
      }
    }
    return copyWith(
      hidden: Set.unmodifiable(disabled),
      delays: Map.unmodifiable(offsets),
    );
  }

  factory DanmakuPreferences.read(SharedPreferences prefs) {
    Map<String, dynamic> value = {};
    try {
      final saved = jsonDecode(prefs.getString('danmaku.settings.v1') ?? '{}');
      if (saved is Map<String, dynamic>) value = saved;
    } catch (_) {
      // Preserve the legacy switches if a preference is malformed.
    }
    bool flag(String name, bool fallback) =>
        value[name] is bool ? value[name] as bool : fallback;
    double range(String name, double min, double max, double fallback) {
      final number = value[name];
      return number is num && number.isFinite
          ? number.toDouble().clamp(min, max)
          : fallback;
    }

    final hidden = value['hidden'];
    final delays = value['delays'];

    return DanmakuPreferences(
      enabled: flag('enabled', prefs.getBool('danmaku.enabled') ?? true),
      automatic: flag('automatic', true),
      hidden: {
        if (hidden is List)
          for (final name in danmakuSourceNames)
            if (hidden.contains(name)) name,
      },
      delays: {
        if (delays is Map)
          for (final name in danmakuSourceNames)
            if (delays[name] case final num seconds)
              if (seconds.isFinite) name: seconds.toDouble().clamp(-3600, 3600),
      },
      compatible: value['compatible'] is String
          ? value['compatible'] as String
          : prefs.getString('danmaku.compatible') ?? '',
      appearance: (
        featured: flag('featured', false),
        scroll: flag('scroll', true),
        top: flag('top', true),
        bottom: flag('bottom', true),
        adaptive: flag('adaptive', true),
        background: flag('background', false),
        opacity: range('opacity', .15, 1, .8),
        fontSize: range('fontSize', 14, 40, 24),
        area: range('area', .2, 1, .5),
        travel: range('travel', 4, 20, 9),
        delay: range('delay', -3600, 3600, 0),
      ),
    );
  }

  DanmakuPreferences copyWith({
    bool? enabled,
    bool? automatic,
    String? compatible,
    DanmakuAppearance? appearance,
    Set<String>? hidden,
    Map<String, double>? delays,
  }) => DanmakuPreferences(
    enabled: enabled ?? this.enabled,
    automatic: automatic ?? this.automatic,
    compatible: compatible ?? this.compatible,
    appearance: appearance ?? this.appearance,
    hidden: hidden ?? this.hidden,
    delays: delays ?? this.delays,
  );

  Future<bool> save(SharedPreferences prefs) => prefs.setString(
    'danmaku.settings.v1',
    jsonEncode({
      'enabled': enabled,
      'automatic': automatic,
      'compatible': compatible,
      'featured': appearance.featured,
      'scroll': appearance.scroll,
      'top': appearance.top,
      'bottom': appearance.bottom,
      'adaptive': appearance.adaptive,
      'background': appearance.background,
      'opacity': appearance.opacity,
      'fontSize': appearance.fontSize,
      'area': appearance.area,
      'travel': appearance.travel,
      'delay': appearance.delay,
      'hidden': hidden.toList(),
      'delays': delays,
    }),
  );
}

extension DanmakuAppearanceChanges on DanmakuAppearance {
  DanmakuAppearance update({
    bool? featured,
    bool? scroll,
    bool? top,
    bool? bottom,
    bool? adaptive,
    bool? background,
    double? opacity,
    double? fontSize,
    double? area,
    double? travel,
    double? delay,
  }) => (
    featured: featured ?? this.featured,
    scroll: scroll ?? this.scroll,
    top: top ?? this.top,
    bottom: bottom ?? this.bottom,
    adaptive: adaptive ?? this.adaptive,
    background: background ?? this.background,
    opacity: opacity ?? this.opacity,
    fontSize: fontSize ?? this.fontSize,
    area: area ?? this.area,
    travel: travel ?? this.travel,
    delay: delay ?? this.delay,
  );
}
