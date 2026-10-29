import '../core/models.dart';

class PlaybackChapter {
  const PlaybackChapter(this.index, this.start, this.title, {this.origin});
  final int index;
  final Duration start;
  final String title;

  /// Current MPV load, or disc session + selected playlist, never a media URL.
  final String? origin;
}

/// Optional capabilities: existing non-MPV backends need not implement them.
abstract class PlaybackChapterBackend {
  Future<List<PlaybackChapter>> readChapters({
    required bool Function() allowed,
  });
}

abstract class SubtitleDelayBackend {
  Future<Duration> readSubtitleDelay({required bool Function() allowed});
  Future<Duration> setSubtitleDelay(
    Duration value, {
    required bool Function() allowed,
  });
}

abstract class SubtitlePositionBackend {
  Future<double> readSubtitlePosition({required bool Function() allowed});
  Future<double> setSubtitlePosition(
    double value, {
    required bool Function() allowed,
  });
}

abstract class DefaultSubtitlePositionBackend {
  bool get usesDefaultSubtitlePosition;
  Future<double> resetSubtitlePosition({required bool Function() allowed});
}

/// Configure before the first media load, without opening or seeking media.
abstract class InitialSubtitlePositionBackend {
  void configureSubtitlePosition(double? value);
}

enum SubtitlePositionScope { regular, discEmbedded }

abstract class ScopedSubtitlePositionBackend {
  SubtitlePositionScope get subtitlePositionScope;
  void configureDiscSubtitlePosition(double? value);
}

class SubtitlePositionPending implements Exception {
  const SubtitlePositionPending();
  @override
  String toString() => '等待字幕出现后即可调整位置';
}

/// Restore authored disc bitmap layout only in automatic mode. Manual position
/// continues to use the established screen-space renderer. Never switches sid,
/// enables subtitles, reloads media or changes any video/color option.
Future<void> writeMpvSubtitleLayout({
  required SubtitlePositionScope scope,
  double? position,
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) write,
  required bool Function() active,
}) async {
  // New native cores consume mode and position in one option snapshot. Older
  // backends retain the existing guarded transaction below.
  String? layoutBefore;
  try {
    layoutBefore = await read('yingyu-subtitle-layout');
  } catch (_) {
    // Optional capability is absent on the retained older native core.
  }
  _active(active);
  final savedLayout = double.tryParse(layoutBefore ?? '');
  if (savedLayout != null &&
      savedLayout.isFinite &&
      (const [-3.0, -2.0, -1.0].contains(savedLayout) ||
          (savedLayout >= 0 && savedLayout <= 100))) {
    if (position != null &&
        (!position.isFinite || position < 0 || position > 100)) {
      throw const AppFailure('字幕位置须在 0% 到 100% 之间');
    }
    final next = position != null
        ? 100 - position
        : scope == SubtitlePositionScope.discEmbedded
        ? -1.0
        : -2.0;
    if ((next - savedLayout).abs() < .0001) return;
    try {
      await write('yingyu-subtitle-layout', next.toStringAsFixed(6));
      _active(active);
      final actual = double.tryParse(await read('yingyu-subtitle-layout'));
      _active(active);
      if (actual == null || !actual.isFinite || (actual - next).abs() > .0001) {
        throw const AppFailure('字幕位置设置未确认');
      }
    } catch (_) {
      if (!active()) rethrow;
      await write('yingyu-subtitle-layout', layoutBefore!);
      _active(active);
      if (double.tryParse(await read('yingyu-subtitle-layout')) !=
          savedLayout) {
        throw const AppFailure('字幕位置失败，原设置也未能恢复');
      }
      _active(active);
      rethrow;
    }
    return;
  }
  if (position != null &&
      (!position.isFinite || position < 0 || position > 100)) {
    throw const AppFailure('字幕位置须在 0% 到 100% 之间');
  }
  _active(active);
  const screen = 'yingyu-subtitle-screen-position';
  const below = 'yingyu-subtitle-below-picture';
  const stretch = 'stretch-image-subs-to-screen';
  final before = <String, String>{};
  for (final key in [screen, below, stretch]) {
    before[key] = await read(key);
    _active(active);
    if (!const {'yes', 'no'}.contains(before[key])) {
      throw const AppFailure('字幕排版状态尚未就绪');
    }
  }
  final oldPosition = await readMpvSubtitlePosition(read: read, active: active);
  final authored =
      scope == SubtitlePositionScope.discEmbedded && position == null;
  Future<void> set(String key, String value) async {
    _active(active);
    await write(key, value);
    _active(active);
    if (await read(key) != value) throw const AppFailure('字幕排版设置未确认');
    _active(active);
  }

  try {
    // Keep image glyph scaling stable before releasing the screen translator.
    if (authored && before[stretch] != 'no') await set(stretch, 'no');
    final nextBelow = !authored && position == null ? 'yes' : 'no';
    if (before[below] != nextBelow) await set(below, nextBelow);
    if (position != null || authored) {
      await writeMpvSubtitlePosition(
        value: position ?? 0,
        read: read,
        write: write,
        active: active,
      );
    }
    final nextScreen = authored ? 'no' : 'yes';
    if (before[screen] != nextScreen) await set(screen, nextScreen);
    _active(active);
  } catch (_) {
    if (!active()) rethrow;
    for (final key in [stretch, below, screen]) {
      try {
        await write(key, before[key]!);
      } catch (_) {
        /* Verify below. */
      }
      _active(active);
    }
    await writeMpvSubtitlePosition(
      value: oldPosition,
      read: read,
      write: write,
      active: active,
    );
    for (final key in [screen, below, stretch]) {
      if (await read(key) != before[key]) {
        throw const AppFailure('字幕排版失败，原设置也未能恢复');
      }
      _active(active);
    }
    rethrow;
  }
}

/// One acknowledged transaction for native bitmap placement and manual sub-pos.
/// Text placement switches only after this succeeds. Never enables a subtitle.
Future<void> writeMpvSubtitlePlacement({
  double? position,
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) write,
  required bool Function() active,
}) async {
  if (position != null &&
      (!position.isFinite || position < 0 || position > 100)) {
    throw const AppFailure('字幕位置须在 0% 到 100% 之间');
  }
  _active(active);
  const option = 'yingyu-subtitle-below-picture';
  final before = await read(option);
  final previous = await readMpvSubtitlePosition(read: read, active: active);
  if (before != 'yes' && before != 'no') {
    throw const AppFailure('播放器未提供字幕默认位置');
  }
  final target = position == null ? 'yes' : 'no';
  try {
    _active(active);
    await write(option, target);
    _active(active);
    if (await read(option) != target) throw const AppFailure('字幕默认位置未确认');
    if (position != null) {
      await writeMpvSubtitlePosition(
        value: position,
        read: read,
        write: write,
        active: active,
      );
    }
    _active(active);
  } catch (_) {
    if (active()) {
      await write('sub-pos', '${100 - previous}');
      _active(active);
      await write(option, before);
      _active(active);
      final restored = await readMpvSubtitlePosition(
        read: read,
        active: active,
      );
      if ((restored - previous).abs() > .001 || await read(option) != before) {
        throw const AppFailure('字幕位置设置失败，原位置也未能恢复');
      }
    }
    rethrow;
  }
}

Future<double> readMpvSubtitlePosition({
  required Future<String> Function(String) read,
  required bool Function() active,
}) async {
  _active(active);
  final value = double.tryParse(await read('sub-pos'));
  _active(active);
  if (value == null || !value.isFinite || value < 0 || value > 100) {
    throw const AppFailure('播放器未提供有效字幕位置');
  }
  return 100 - value;
}

Future<double> writeMpvSubtitlePosition({
  required double value,
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) write,
  required bool Function() active,
}) async {
  if (!value.isFinite || value < 0 || value > 100) {
    throw const AppFailure('字幕位置须在 0% 到 100% 之间');
  }
  final before = await readMpvSubtitlePosition(read: read, active: active);
  _active(active);
  try {
    await write('sub-pos', (100 - value).toStringAsFixed(3));
    final actual = await readMpvSubtitlePosition(read: read, active: active);
    if ((actual - value).abs() > .001) {
      throw const AppFailure('播放器未确认字幕位置，原位置已请求恢复');
    }
    return actual;
  } catch (_) {
    if (active()) {
      await write('sub-pos', '${100 - before}');
      final restored = await readMpvSubtitlePosition(
        read: read,
        active: active,
      );
      if ((restored - before).abs() > .001) {
        throw const AppFailure('字幕位置设置失败，原位置也未能恢复');
      }
    }
    rethrow;
  }
}

void _active(bool Function() active) {
  if (!active()) throw const AppFailure('播放会话已改变，请重新打开面板');
}

/// Read only MPV's already opened chapter list. No metadata/HTTP probe or cache.
/// Pinned mpv 78d4374 DOCS/man/input.rst: chapter-list/count and N/title,time.
Future<List<PlaybackChapter>> readMpvChapters({
  required Future<String> Function(String) read,
  required bool Function() active,
  required Duration duration,
  String? origin,
}) async {
  _active(active);
  final path = await read('path');
  _active(active);
  final count = int.tryParse(await read('chapter-list/count'));
  _active(active);
  if (count == null || count < 0 || count > 4096) {
    throw const AppFailure('播放器未提供有效章节资料');
  }
  final chapters = <PlaybackChapter>[];
  for (var index = 0; index < count; index++) {
    _active(active);
    final seconds = double.tryParse(await read('chapter-list/$index/time'));
    _active(active);
    if (seconds == null || !seconds.isFinite || seconds < 0 || seconds > 1e9) {
      throw const AppFailure('章节时间无效，未执行跳转');
    }
    final at = Duration(microseconds: (seconds * 1000000).round());
    if (duration > Duration.zero && at > duration ||
        chapters.isNotEmpty && at < chapters.last.start) {
      throw const AppFailure('章节时间与当前媒体不一致，未执行跳转');
    }
    final rawTitle = await read('chapter-list/$index/title');
    _active(active);
    final title = rawTitle.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    chapters.add(
      PlaybackChapter(
        index,
        at,
        title.isEmpty ? '章节 ${index + 1}' : title,
        origin: origin,
      ),
    );
  }
  final afterPath = await read('path');
  _active(active);
  final afterCount = int.tryParse(await read('chapter-list/count'));
  _active(active);
  if (path != afterPath || afterCount != count) {
    throw const AppFailure('媒体章节已改变，请重新打开面板');
  }
  return List.unmodifiable(chapters);
}

/// Prefer the opened demuxer's real chapters. EDL !no_chapters may suppress
/// these; then reuse only the already parsed, currently selected disc title.
Future<List<PlaybackChapter>> readAvailableChapters({
  required Future<String> Function(String) read,
  required bool Function() active,
  required Duration duration,
  required String origin,
  List<int>? discTicks,
  int? discDurationTicks,
  String? discOrigin,
}) async {
  final chapters = await readMpvChapters(
    read: read,
    active: active,
    duration: duration,
    origin: origin,
  );
  _active(active);
  if (chapters.isNotEmpty || discTicks == null) return chapters;
  if (discDurationTicks == null ||
      discDurationTicks <= 0 ||
      discOrigin == null ||
      discOrigin.isEmpty ||
      discTicks.length > 4096) {
    throw const AppFailure('当前原盘章节资料无效');
  }
  final result = <PlaybackChapter>[];
  var previous = -1;
  for (var index = 0; index < discTicks.length; index++) {
    final ticks = discTicks[index];
    if (ticks < 0 || ticks > discDurationTicks || ticks < previous) {
      throw const AppFailure('原盘章节时间无效，未执行跳转');
    }
    previous = ticks;
    // libbluray bluray.h BLURAY_TITLE_CHAPTER.start: playlist time, 90kHz.
    // navigation.c _fill_mark already subtracts the clip's nonzero in_time.
    final at = Duration(microseconds: (ticks * 1000000 + 45000) ~/ 90000);
    result.add(
      PlaybackChapter(index, at, '章节 ${index + 1}', origin: discOrigin),
    );
  }
  _active(active);
  return List.unmodifiable(result);
}

int currentPlaybackChapter(List<PlaybackChapter> chapters, Duration position) {
  var current = -1;
  for (final chapter in chapters) {
    if (chapter.start > position) break;
    current = chapter.index;
  }
  return current;
}

Future<Duration> readMpvSubtitleDelay({
  required Future<String> Function(String) read,
  required bool Function() active,
}) async {
  _active(active);
  final seconds = double.tryParse(await read('sub-delay'));
  _active(active);
  if (seconds == null || !seconds.isFinite || seconds.abs() > 1e9) {
    throw const AppFailure('播放器未提供有效字幕延迟');
  }
  return Duration(microseconds: (seconds * 1000000).round());
}

/// Pinned mpv options.rst and dec_sub.c: positive delays subtitle presentation;
/// negative advances it. Only sub-delay is written, never sid or visibility.
Future<Duration> writeMpvSubtitleDelay({
  required Duration value,
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) write,
  required bool Function() active,
}) async {
  final original = await readMpvSubtitleDelay(read: read, active: active);
  _active(active);
  try {
    await write('sub-delay', '${value.inMicroseconds / 1000000}');
    final actual = await readMpvSubtitleDelay(read: read, active: active);
    if ((actual - value).abs() > const Duration(microseconds: 2)) {
      throw const AppFailure('MPV 未确认字幕延迟，原值已请求恢复');
    }
    return actual;
  } catch (_) {
    // A retired media/account must not be mutated by a late rollback.
    if (active()) {
      await write('sub-delay', '${original.inMicroseconds / 1000000}');
      final restored = await readMpvSubtitleDelay(read: read, active: active);
      if ((restored - original).abs() > const Duration(microseconds: 2)) {
        throw const AppFailure('字幕延迟设置失败，原值也未能恢复');
      }
    }
    rethrow;
  }
}

String subtitleDelayLabel(Duration value) {
  var seconds = (value.inMicroseconds / 1000000).toStringAsFixed(3);
  seconds = seconds.replaceFirst(RegExp(r'0+$'), '');
  if (seconds.endsWith('.')) seconds += '0';
  return '${value > Duration.zero ? '+' : ''}$seconds 秒';
}
