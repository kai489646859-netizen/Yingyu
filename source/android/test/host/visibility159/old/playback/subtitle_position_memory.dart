import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/accounts.dart' show accountKey;
import '../core/models.dart';
import 'playback_adjustments.dart' show SubtitlePositionScope;

enum SubtitleViewport { phone, tablet }

/// Uses existing metadata only. Missing season information must not merge
/// unrelated episodes, and a real special-season number zero is valid.
class SubtitlePositionTarget {
  const SubtitlePositionTarget._(this.key, this.season);
  final String key;
  final bool season;

  static SubtitlePositionTarget? resolve(Session account, MediaItem item) {
    final id = item.id.trim();
    if (id.isEmpty) return null;
    final seasonId = item.data['SeasonId']?.toString().trim() ?? '';
    final seriesId = item.data['SeriesId']?.toString().trim() ?? '';
    final number = int.tryParse('${item.data['ParentIndexNumber']}');
    final season =
        item.type == 'Episode' &&
        (seasonId.isNotEmpty ||
            (seriesId.isNotEmpty && number != null && number >= 0));
    final parts = <Object?>[
      accountKey(account),
      if (season && seasonId.isNotEmpty) ...[
        'season',
        seasonId,
      ] else if (season) ...[
        'season-number',
        seriesId,
        number,
      ] else ...[
        'item',
        id,
      ],
    ];
    return SubtitlePositionTarget._(
      sha256.convert(utf8.encode(jsonEncode(parts))).toString(),
      season,
    );
  }
}

/// A local, normalized user preference. Null uses default placement; zero is a
/// deliberate screen-bottom position. An owner lease fences retired players.
class SubtitlePositionMemory {
  SubtitlePositionMemory(this.prefs);
  final SharedPreferences prefs;
  final _owners = <String, Object>{};
  Future<void> _tail = Future.value();
  // Null addresses legacy data only. Playback always supplies a media target;
  // an unowned global value cannot be inherited by unrelated films or seasons.
  String _key(
    SubtitleViewport viewport,
    SubtitlePositionScope scope,
    String? resource,
  ) => resource != null
      ? 'yingyu.subtitles.position.${viewport.name}.${scope.name}.resource.v1.$resource'
      : scope == SubtitlePositionScope.regular
      ? 'yingyu.subtitles.position.${viewport.name}.v1'
      : 'yingyu.subtitles.position.${viewport.name}.disc.v1';

  double? read(
    SubtitleViewport viewport, {
    SubtitlePositionScope scope = SubtitlePositionScope.regular,
    String? resource,
  }) {
    final value = prefs.get(_key(viewport, scope, resource));
    return value is num && value.isFinite && value >= 0 && value <= 100
        ? value.toDouble()
        : null;
  }

  Object claim(
    SubtitleViewport viewport, {
    SubtitlePositionScope scope = SubtitlePositionScope.regular,
    String? resource,
  }) {
    final owner = Object();
    _owners[_key(viewport, scope, resource)] = owner;
    return owner;
  }

  void release(
    SubtitleViewport viewport,
    Object owner, {
    SubtitlePositionScope scope = SubtitlePositionScope.regular,
    String? resource,
  }) {
    final key = _key(viewport, scope, resource);
    if (_owners[key] == owner) _owners.remove(key);
  }

  Future<void> save(
    SubtitleViewport viewport,
    Object owner,
    double? value, {
    required bool Function() active,
    SubtitlePositionScope scope = SubtitlePositionScope.regular,
    String? resource,
  }) {
    if (value != null && (!value.isFinite || value < 0 || value > 100)) {
      return Future.error(const AppFailure('字幕位置须在 0% 到 100% 之间'));
    }
    final job = _tail.then((_) async {
      final key = _key(viewport, scope, resource);
      if (_owners[key] != owner || !active()) return;
      final saved = value == null
          ? await prefs.remove(key)
          : await prefs.setDouble(key, value);
      if (!saved) throw const AppFailure('字幕位置已调整，但位置记忆保存失败');
    });
    _tail = job.then<void>((_) {}, onError: (Object _) {});
    return job;
  }
}
