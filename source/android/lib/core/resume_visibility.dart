import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

String resumeGroup(MediaItem item) {
  final series = item.data['SeriesId']?.toString() ?? '';
  return (item.type.toLowerCase() == 'episode' && series.trim().isNotEmpty
          ? 'series:$series'
          : 'item:${item.id}')
      .toLowerCase();
}

/// A display exclusion is separate from durable playback positions and metadata.
class ResumeVisibility {
  ResumeVisibility(this.prefs, Session account)
    : key =
          'yingyu.resume.hidden.v1.${Uri.encodeComponent(account.base.toString())}.${account.userId}' {
    try {
      hidden.addAll(object(jsonDecode(prefs.getString(key) ?? '{}')));
    } catch (_) {
      /* Optional display metadata must not prevent login. */
    }
  }
  final SharedPreferences prefs;
  final String key;
  final Map<String, dynamic> hidden = {};
  Future<void> _tail = Future.value();
  bool allows(MediaItem item) => !hidden.containsKey(resumeGroup(item));
  Future<void> save() {
    final text = jsonEncode(hidden);
    final job = _tail.then((_) async {
      if (!await prefs.setString(key, text)) {
        throw const AppFailure('继续观看的本机隐藏记录保存失败');
      }
    });
    _tail = job.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return job;
  }

  Future<void> hide(MediaItem item, Json userData) {
    hidden[resumeGroup(item)] = {
      'id': item.id,
      'lastPlayed':
          userData['LastPlayedDate'] ??
          object(item.data['UserData'])['LastPlayedDate'],
    };
    return save();
  }

  Future<void> played(MediaItem item) async {
    if (hidden.remove(resumeGroup(item)) != null) await save();
  }

  /// Only a server refresh with a newer playback date can release an exclusion.
  Future<void> observeServer(Iterable<MediaItem> items) async {
    var changed = false;
    for (final item in items) {
      final group = resumeGroup(item);
      if (!hidden.containsKey(group)) continue;
      final before = DateTime.tryParse(
        object(hidden[group])['lastPlayed']?.toString() ?? '',
      );
      final after = DateTime.tryParse(
        object(item.data['UserData'])['LastPlayedDate']?.toString() ?? '',
      );
      if (before != null && after != null && after.isAfter(before)) {
        hidden.remove(group);
        changed = true;
      }
    }
    if (changed) await save();
  }
}
