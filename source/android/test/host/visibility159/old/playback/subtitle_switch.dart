import '../core/models.dart';

/// Restore both the old selection and renderer visibility after a partial
/// failure. Never restore old properties into another media load.
Future<void> protectSubtitleSwitch({
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) restore,
  required Future<void> Function() apply,
  required bool Function() active,
}) async {
  if (!active()) throw const AppFailure('字幕操作已取消');
  final old = <String, String>{};
  for (final key in ['sid', 'sub-visibility']) {
    old[key] = await read(key).timeout(const Duration(milliseconds: 600));
  }
  if (!active()) throw const AppFailure('字幕操作已取消');
  if ((old['sid'] != 'no' &&
          old['sid'] != 'auto' &&
          int.tryParse(old['sid']!) == null) ||
      !const {'yes', 'no'}.contains(old['sub-visibility'])) {
    throw const AppFailure('字幕状态尚未就绪，请重试');
  }
  try {
    await apply();
  } catch (_) {
    if (!active()) throw const AppFailure('字幕操作已被换片或退出取消');
    for (final entry in old.entries) {
      if (!active()) throw const AppFailure('字幕操作已被换片或退出取消');
      try {
        await restore(entry.key, entry.value);
      } catch (_) {
        /* Verify every property below. */
      }
    }
    try {
      for (final entry in old.entries) {
        if (!active()) throw const AppFailure('字幕操作已被换片或退出取消');
        if (await read(entry.key).timeout(const Duration(milliseconds: 600)) !=
            entry.value) {
          throw StateError('Subtitle restore unconfirmed');
        }
      }
    } catch (_) {
      throw const AppFailure('字幕切换失败，原字幕显示状态未能完整恢复，请重新选择');
    }
    throw const AppFailure('字幕切换失败，已恢复原字幕与显示设置，请重新选择');
  }
}
