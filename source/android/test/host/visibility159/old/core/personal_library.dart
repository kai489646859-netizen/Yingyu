import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'accounts.dart';
import 'browse_cache.dart';
import 'models.dart';

enum SavedList { watchlist, favorites }

extension SavedListLabel on SavedList {
  String get label => this == SavedList.watchlist ? '想看' : '收藏';
}

class IntroRange {
  const IntroRange(this.start, this.end);
  final Duration start, end;
  bool validFor(Duration duration) =>
      start >= Duration.zero && end > start && end < duration;
  bool contains(Duration position, Duration duration) =>
      validFor(duration) && position >= start && position < end;
}

enum SkipScope { item, season, series }

/// Credits use a distance from the real end, so a season rule also fits episodes
/// with different running times. Automatic actions are always explicit choices.
class SkipRule {
  const SkipRule({
    this.enabled = true,
    this.intro,
    this.creditsRemaining,
    this.autoIntro = false,
    this.autoCredits = false,
  });
  final bool enabled, autoIntro, autoCredits;
  final IntroRange? intro;
  final Duration? creditsRemaining;

  String? validationError(Duration duration) {
    if (!enabled) return null;
    if (duration <= Duration.zero) return '尚未获得有效时长，无法保存片头片尾';
    if (intro == null && creditsRemaining == null) {
      return '请至少启用片头或片尾，或关闭此范围规则';
    }
    if (intro != null && !intro!.validFor(duration)) {
      return '片头结束时间必须晚于开始，并早于本集结束';
    }
    final credits = creditsRemaining;
    if (credits != null && (credits <= Duration.zero || credits >= duration)) {
      return '片尾剩余时长必须大于零，并小于当前影片时长';
    }
    if (intro != null && credits != null && intro!.end > duration - credits) {
      return '片头与片尾不能重叠，请缩短其中一个区间';
    }
    return null;
  }

  bool validFor(Duration duration) => validationError(duration) == null;
  bool introContains(Duration position, Duration duration) =>
      enabled &&
      validFor(duration) &&
      intro?.contains(position, duration) == true;
  bool creditsContains(Duration position, Duration duration) =>
      enabled &&
      validFor(duration) &&
      creditsRemaining != null &&
      position >= duration - creditsRemaining! &&
      position < duration;

  Json toJson() => {
    'enabled': enabled,
    if (intro != null) ...{
      'introStart': intro!.start.inMilliseconds,
      'introEnd': intro!.end.inMilliseconds,
    },
    if (creditsRemaining != null)
      'creditsRemaining': creditsRemaining!.inMilliseconds,
    'autoIntro': autoIntro,
    'autoCredits': autoCredits,
  };

  factory SkipRule.fromJson(Json value) {
    final start = value['introStart'], end = value['introEnd'];
    if (value['enabled'] is! bool ||
        value['autoIntro'] is! bool ||
        value['autoCredits'] is! bool ||
        ((start != null || end != null) && (start is! int || end is! int)) ||
        (value['creditsRemaining'] != null &&
            value['creditsRemaining'] is! int)) {
      throw const AppFailure('片头片尾规则无法读取，原有资料未覆盖');
    }
    return SkipRule(
      enabled: value['enabled'] as bool,
      intro: start == null
          ? null
          : IntroRange(
              Duration(milliseconds: start as int),
              Duration(milliseconds: end as int),
            ),
      creditsRemaining: value['creditsRemaining'] == null
          ? null
          : Duration(milliseconds: value['creditsRemaining'] as int),
      autoIntro: value['autoIntro'] as bool,
      autoCredits: value['autoCredits'] as bool,
    );
  }
}

class ResolvedSkipRule {
  const ResolvedSkipRule(this.scope, this.rule, {this.legacy = false});
  final SkipScope scope;
  final SkipRule rule;
  final bool legacy;
}

/// Durable, local user choices. Only sanitized display data is stored. Every
/// key includes the server URL and user ID; TMDB never joins personal state.
class PersonalLibrary extends ChangeNotifier {
  PersonalLibrary(this.prefs);
  final SharedPreferences prefs;
  final Map<String, Json> _loaded = {};
  final Map<String, int> _skipRevisions = {};
  // Only successfully committed skip edits invalidate a queued automatic seek.
  int skipRevision(Session account) => _skipRevisions[storageKey(account)] ?? 0;
  Future<void> _tail = Future.value();
  String storageKey(Session account) =>
      'yingyu.personal.v1.${base64Url.encode(utf8.encode(accountKey(account)))}';

  Json _read(Session account) => _loaded.putIfAbsent(storageKey(account), () {
    try {
      final data = jsonDecode(prefs.getString(storageKey(account)) ?? '{}');
      if (data is! Map) throw const FormatException();
      for (final key in [
        'watchlist',
        'favorites',
        'intros',
        'skipRules',
        'favoriteKnown',
      ]) {
        if (data.containsKey(key) && data[key] is! Map) {
          throw const FormatException();
        }
      }
      return object(data);
    } catch (_) {
      throw const AppFailure('想看与收藏资料无法读取，原有资料未覆盖');
    }
  });

  Future<void> _write(
    Session account,
    void Function(Json) change, {
    bool skipEdit = false,
  }) {
    final result = _tail.then((_) async {
      final data = object(jsonDecode(jsonEncode(_read(account))));
      change(data);
      if (!await prefs.setString(storageKey(account), jsonEncode(data))) {
        throw const AppFailure('保存失败，请重试');
      }
      _loaded[storageKey(account)] = data;
      if (skipEdit) {
        _skipRevisions[storageKey(account)] = skipRevision(account) + 1;
      }
      notifyListeners();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  bool contains(Session account, SavedList list, String id) =>
      object(_read(account)[list.name]).containsKey(id);

  List<MediaItem> items(Session account, SavedList list) => object(
    _read(account)[list.name],
  ).values.map((v) => MediaItem(object(v))).toList().reversed.toList();

  Future<void> setSaved(
    Session account,
    SavedList list,
    MediaItem item,
    bool value,
  ) => _write(account, (data) {
    if (item.id.isEmpty) throw const AppFailure('资源编号缺失，无法保存');
    final values = object(data[list.name]);
    values.remove(item.id);
    if (value) values[item.id] = displayMetadata(item.data);
    data[list.name] = values;
  });

  /// Legacy local favorites remain visible until individually acknowledged by
  /// Emby. Known server removals must not be re-uploaded on the next refresh.
  List<MediaItem> unsyncedFavorites(Session account) =>
      items(account, SavedList.favorites)
          .where(
            (item) =>
                !object(_read(account)['favoriteKnown']).containsKey(item.id),
          )
          .toList();

  Future<void> acknowledgeFavorite(
    Session account,
    MediaItem item,
    bool value,
  ) => _write(account, (data) {
    final values = object(data['favorites']);
    values.remove(item.id);
    if (value) values[item.id] = displayMetadata(item.data);
    data['favorites'] = values;
    data['favoriteKnown'] = {...object(data['favoriteKnown']), item.id: true};
  });

  Future<void> reconcileFavorites(Session account, List<MediaItem> remote) =>
      _write(account, (data) {
        final known = object(data['favoriteKnown']);
        final values = object(data['favorites']);
        values.removeWhere((id, _) => known.containsKey(id));
        for (final item in remote) {
          values[item.id] = displayMetadata(item.data);
          known[item.id] = true;
        }
        data['favorites'] = values;
        data['favoriteKnown'] = known;
      });

  // Use the concrete server series/season identity, never a title or TMDB.
  static String? introScope(MediaItem item) {
    final series = item.data['SeriesId']?.toString() ?? '';
    if (item.type != 'Episode' || series.isEmpty) return null;
    final season = item.data['SeasonId']?.toString() ?? '';
    final number = item.data['ParentIndexNumber'];
    if (season.isEmpty && number == null) return null;
    return jsonEncode([
      series,
      season.isNotEmpty ? 'id:$season' : 'number:$number',
    ]);
  }

  static String? skipScopeKey(MediaItem item, SkipScope scope) {
    final series = item.data['SeriesId']?.toString() ?? '';
    final season = item.data['SeasonId']?.toString() ?? '';
    switch (scope) {
      case SkipScope.item:
        return item.id.isEmpty ? null : jsonEncode(['item', item.id]);
      case SkipScope.season:
        if (item.type != 'Episode' || series.isEmpty) return null;
        if (season.isNotEmpty) {
          return jsonEncode(['season', series, 'id:$season']);
        }
        final number = item.data['ParentIndexNumber'];
        final parsed = int.tryParse(number?.toString() ?? '');
        if (parsed == null || parsed < 0) return null;
        return jsonEncode(['season', series, 'number:$number']);
      case SkipScope.series:
        return item.type != 'Episode' || series.isEmpty
            ? null
            : jsonEncode(['series', series]);
    }
  }

  IntroRange? _legacyIntro(Session account, MediaItem item) {
    final scope = introScope(item);
    if (scope == null) return null;
    final value = object(object(_read(account)['intros'])[scope]);
    if (value['start'] is! int || value['end'] is! int) return null;
    return IntroRange(
      Duration(milliseconds: value['start']),
      Duration(milliseconds: value['end']),
    );
  }

  ResolvedSkipRule? skipRuleAt(
    Session account,
    MediaItem item,
    SkipScope scope,
  ) {
    final key = skipScopeKey(item, scope);
    final rules = object(_read(account)['skipRules']);
    if (key != null && rules.containsKey(key)) {
      return ResolvedSkipRule(scope, SkipRule.fromJson(object(rules[key])));
    }
    if (scope == SkipScope.season) {
      final legacy = _legacyIntro(account, item);
      if (legacy != null) {
        return ResolvedSkipRule(scope, SkipRule(intro: legacy), legacy: true);
      }
    }
    return null;
  }

  ResolvedSkipRule? resolveSkipRule(Session account, MediaItem item) {
    for (final scope in SkipScope.values) {
      final resolved = skipRuleAt(account, item, scope);
      if (resolved != null) return resolved;
    }
    return null;
  }

  Future<void> setSkipRule(
    Session account,
    MediaItem item,
    SkipScope scope,
    SkipRule? value,
    Duration duration,
  ) => _write(account, (data) {
    final key = skipScopeKey(item, scope);
    if (key == null) throw const AppFailure('缺少此范围的资源编号，无法保存规则');
    if (value != null) {
      final error = value.validationError(duration);
      if (error != null) throw AppFailure(error);
    }
    final rules = object(data['skipRules']);
    rules.remove(key);
    if (value != null) rules[key] = value.toJson();
    data['skipRules'] = rules;
    // Do not resurrect an old season range after its replacement is removed.
    if (scope == SkipScope.season) {
      final legacy = introScope(item);
      if (legacy != null) {
        final ranges = object(data['intros'])..remove(legacy);
        data['intros'] = ranges;
      }
    }
  }, skipEdit: true);

  IntroRange? intro(Session account, MediaItem item) {
    final resolved = skipRuleAt(account, item, SkipScope.season);
    return resolved?.rule.enabled == true ? resolved!.rule.intro : null;
  }

  Future<void> setIntro(
    Session account,
    MediaItem item,
    IntroRange? value,
    Duration duration,
  ) => _write(account, (data) {
    final scope = introScope(item);
    if (scope == null) throw const AppFailure('缺少剧集或季信息，无法保存片头');
    if (value != null && !value.validFor(duration)) {
      throw const AppFailure('片头结束时间必须晚于开始，并早于本集结束');
    }
    final ranges = object(data['intros']);
    ranges.remove(scope);
    if (value != null) {
      ranges[scope] = {
        'start': value.start.inMilliseconds,
        'end': value.end.inMilliseconds,
      };
    }
    data['intros'] = ranges;
    // Existing callers still edit only the season intro. Preserve any newer
    // credits/automatic choices stored alongside it.
    final key = skipScopeKey(item, SkipScope.season);
    final rules = object(data['skipRules']);
    if (key != null && rules.containsKey(key)) {
      final old = SkipRule.fromJson(object(rules[key]));
      final replacement = SkipRule(
        enabled: old.enabled && (value != null || old.creditsRemaining != null),
        intro: value,
        creditsRemaining: old.creditsRemaining,
        autoIntro: old.autoIntro,
        autoCredits: old.autoCredits,
      );
      final error = replacement.validationError(duration);
      if (error != null) throw AppFailure(error);
      rules[key] = replacement.toJson();
      data['skipRules'] = rules;
    }
  }, skipEdit: true);
}
