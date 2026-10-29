import 'dart:convert';
import 'models.dart';

/// Compare server observations, not device clocks or the largest position.
/// Watching again or seeking backwards is also a legitimate newer checkpoint.
String progressFingerprint(MediaItem item) {
  final user = object(item.data['UserData']);
  return jsonEncode([
    item.resume.inMilliseconds,
    user['LastPlayedDate'],
    user['Played'],
    user['PlayCount'],
  ]);
}

/// Keep normal checkpoint rounding tolerance without treating a positive
/// playback position as an acknowledgement of the start boundary (or reverse).
bool progressMatches(Duration actual, Duration expected) {
  if (actual.isNegative || expected.isNegative) return false;
  if (actual == Duration.zero || expected == Duration.zero) {
    return actual == expected;
  }
  return (actual - expected).abs() <= const Duration(seconds: 2);
}

({Duration position, String reason}) resolveResume(
  MediaItem server,
  Duration? pending,
  String? baseline,
) {
  if (pending == null || progressMatches(server.resume, pending)) {
    return (position: server.resume, reason: '服务器');
  }
  if (baseline != null && baseline == progressFingerprint(server)) {
    return (position: pending, reason: '本机未同步；服务器记录未改变');
  }
  // Upgrade legacy pending records without inventing an age for them. A
  // positive server checkpoint wins; a rejected zero keeps the recovery point.
  if (baseline == null && server.resume == Duration.zero) {
    return (position: pending, reason: '旧版本机未同步；服务器位置为零');
  }
  return (position: server.resume, reason: '服务器记录已更新');
}
