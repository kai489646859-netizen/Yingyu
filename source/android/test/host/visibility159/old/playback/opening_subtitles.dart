import 'package:media_kit/media_kit.dart' show SubtitleTrack;
import '../core/models.dart';
import 'tracks.dart';

/// Read parsed stream metadata in on_preloaded, before current-tracks and the
/// initial exact seek exist. Unknown fields never become guessed track IDs.
Future<List<TrackOption>> readOpeningSubtitles(
  Future<String> Function(String) read,
  bool Function() active, {
  Map<int, String>? discLanguages,
}) async {
  final count = int.tryParse(await read('track-list/count'));
  if (!active() || count == null || count < 1 || count > 512) return const [];
  final result = <TrackOption>[
    const TrackOption('auto', '自动', SubtitleTrack('auto', null, null)),
    const TrackOption('no', '关闭字幕', SubtitleTrack('no', null, null)),
  ];
  for (var i = 0; i < count; i++) {
    if (!active()) return const [];
    final key = 'track-list/$i';
    if (await read('$key/type') != 'sub') continue;
    final id = await read('$key/id');
    if ((int.tryParse(id) ?? 0) <= 0 || result.any((t) => t.id == id)) {
      return const [];
    }
    final rawLanguage = await read('$key/lang');
    final title = await read('$key/title');
    final codec = await read('$key/codec');
    final external = await read('$key/external') == 'yes';
    final pid = int.tryParse(await read('$key/src-id'));
    final language = resolvedTrackLanguage(
      rawLanguage,
      pid,
      discLanguages,
      external: external,
    );
    result.add(
      TrackOption(
        id,
        title,
        SubtitleTrack(id, title, language, codec: codec),
        title: title,
        language: language,
        codec: codec,
        external: external,
        forced: await read('$key/forced') == 'yes',
        isDefault: await read('$key/default') == 'yes',
        sourcePid: pid,
        ffIndex: discLanguages == null
            ? int.tryParse(await read('$key/ff-index'))
            : null,
      ),
    );
  }
  return active() ? result : const [];
}

/// A bounded subtitle read window, not a delay or a relaxed target. MKV takes
/// a per-demuxer snapshot before open and retains it for that media. MPEG-TS
/// uses a temporary initial-seek offset. Restore the player options before
/// normal playback or before handing native IO to another media load.
class OpeningSubtitleRead {
  final _saved = <String, String>{};
  int _epoch = 0;

  Future<bool> prepare({
    required String container,
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
    required bool Function() active,
  }) async {
    if (!active()) return false;
    final epoch = ++_epoch;
    final mkv = const {
      'mkv',
      'matroska',
      'webm',
      'matroska,webm',
    }.contains(container);
    final key = mkv
        ? 'demuxer-mkv-subtitle-preroll-secs'
        : 'hr-seek-demuxer-offset';
    if (_saved.containsKey(key)) return true;
    try {
      final value = await read(key);
      final seconds = double.tryParse(value);
      if (!active() || seconds == null || !seconds.isFinite || seconds < 0) {
        return false;
      }
      if (seconds >= 10) return true;
      _saved[key] = value;
      await write(key, '10');
      if (epoch != _epoch) return false;
      final applied = double.tryParse(await read(key));
      if (epoch != _epoch) return false;
      if (!active() || applied != 10) {
        await restore(read: read, write: write);
        return false;
      }
      return true;
    } catch (_) {
      if (epoch == _epoch) await restore(read: read, write: write);
      return false;
    }
  }

  Future<void> restore({
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) async {
    ++_epoch;
    for (final key in _saved.keys.toList().reversed) {
      final value = _saved[key]!;
      await write(key, value);
      if (await read(key) != value) throw const AppFailure('续播字幕读取参数恢复失败');
      _saved.remove(key);
    }
  }
}
