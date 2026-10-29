import 'dart:async';
import 'runtime_health.dart';
import 'audio_refresh.dart';

enum AudioSwitchResult { unchanged, disabled, verified, deferred }

// Exact fixed-MPV audio-chain failures only; unrelated cplayer errors retain
// their terminal path. A transaction must still verify or report rollback.
bool isAudioTrackInitError(String prefix, String level, String text) =>
    level == 'error' &&
    (prefix == 'ad' ||
        prefix == 'cplayer' &&
            const {
              'Audio filter initialized failed!',
              'Could not open/initialize audio device -> no sound.',
              'Error reinitializing audio.',
            }.contains(text.trim()));

class AudioSwitchFailure implements Exception {
  const AudioSwitchFailure(this.restored, this.deferred);
  final bool restored, deferred;
  @override
  String toString() => restored
      ? '所选音轨未能正常输出，已恢复原音轨${deferred ? "；暂停中，恢复播放后继续核对" : ""}'
      : '所选音轨及原音轨均未恢复正常输出，请重新选择或退出重试';
}

class AudioSwitchCancelled implements Exception {
  const AudioSwitchCancelled();
}

/// Selection IDs are only acknowledgements. Verify fresh output, and preserve
/// the old choice on failure. All reads concern the current player; no reopen.
Future<AudioSwitchResult> switchAudioTrack({
  required String requested,
  required bool disc,
  required Future<String> Function(String) read,
  required Future<void> Function(String) select,
  required Future<void> Function() refresh,
  required bool Function() active,
  required bool Function() playing,
  required int Function() packetErrors,
  bool Function()? decoderRejected,
  void Function(String)? record,
  Duration initialWait = const Duration(seconds: 1),
  Duration outputWait = const Duration(seconds: 6),
  Duration wallLimit = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 100),
}) async {
  void check() {
    if (!active()) throw const AudioSwitchCancelled();
  }

  Future<String> property(String key) =>
      read(key).timeout(const Duration(milliseconds: 600));
  Future<String> optional(String key) async {
    try {
      return await property(key);
    } catch (_) {
      return 'unknown';
    }
  }

  Future<String> set(String id) async {
    check();
    await select(id);
    check();
    final actual = await property('aid');
    check();
    if (id == 'auto' ? int.tryParse(actual) == null : actual != id) {
      throw StateError('Audio track selection unconfirmed');
    }
    return actual;
  }

  Future<AudioSwitchResult?> confirm(
    String id,
    Duration budget, {
    bool refreshOnError = false,
  }) async {
    final clock = Stopwatch()..start();
    var last = Duration.zero, used = Duration.zero;
    var running = false;
    Duration? audio, video;
    var clockSeen = false;
    while (clock.elapsed < wallLimit && used < budget) {
      check();
      if (packetErrors() >= 8 ||
          decoderRejected?.call() == true ||
          refreshOnError && packetErrors() > 0) {
        return null;
      }
      try {
        final values = await Future.wait([
          property('aid'),
          optional('audio-pts'),
          optional('time-pos'),
          optional('seeking'),
          optional('paused-for-cache'),
          optional('audio-params/samplerate'),
        ]);
        check();
        if (packetErrors() >= 8 || decoderRejected?.call() == true) return null;
        // Active ownership still matches: MPV deselecting a failed decoder is
        // a failed selection, not a newer user intent. Restore the old track.
        if (values[0] != id) {
          record?.call('音轨输出核对未通过：原生选择已改变');
          return null;
        }
        // Paused output cannot demonstrate advancing clocks. Never start play.
        if (!playing()) {
          if ((int.tryParse(values[5]) ?? 0) > 0) {
            return AudioSwitchResult.deferred;
          }
          await Future<void>.delayed(interval);
          continue;
        }
        final now = clock.elapsed;
        final ready = values[3] == 'no' && values[4] == 'no';
        if (running && ready) used += now - last;
        last = now;
        running = ready;
        final a = mediaClock(values[1]), v = mediaClock(values[2]);
        if (ready && a != null && v != null) {
          clockSeen = true;
          if (audio != null &&
              video != null &&
              a - audio >= const Duration(milliseconds: 120) &&
              v - video >= const Duration(milliseconds: 120)) {
            return AudioSwitchResult.verified;
          }
          if (audio == null || video == null || a < audio || v < video) {
            audio = a;
            video = v;
          }
        } else {
          audio = video = null;
        }
      } on AudioSwitchCancelled {
        rethrow;
      } catch (_) {
        audio = video = null;
        running = false;
      }
      await Future<void>.delayed(interval);
    }
    check();
    record?.call(
      '音轨输出核对未通过：音视频时钟曾同时可读=$clockSeen；运行观察=${used.inMilliseconds} ms；总等待=${clock.elapsedMilliseconds} ms',
    );
    return null;
  }

  check();
  final old = await property('aid');
  check();
  if (requested == old) return AudioSwitchResult.unchanged;
  try {
    final actual = await set(requested);
    if (actual == old) return AudioSwitchResult.unchanged;
    if (actual == 'no') return AudioSwitchResult.disabled;
    if (!disc) {
      final ready = await confirm(actual, initialWait, refreshOnError: true);
      if (ready != null) return ready;
    }
    check();
    record?.call('新音轨需要从当前位置补齐解码起点；当前媒体内精确刷新一次，不重新解析入口');
    await refresh();
    check();
    final ready = await confirm(actual, outputWait);
    if (ready != null) return ready;
  } on AudioSwitchCancelled {
    rethrow;
  } on AudioRefreshRestoreFailure {
    rethrow;
  } catch (_) {
    check();
  }
  check();
  record?.call('新音轨未恢复输出，尝试恢复原音轨；失败选择不会保存');
  try {
    final restored = await set(old);
    if (restored == 'no') throw const AudioSwitchFailure(true, false);
    await refresh();
    check();
    final result = await confirm(restored, outputWait);
    if (result != null) {
      throw AudioSwitchFailure(true, result == AudioSwitchResult.deferred);
    }
  } on AudioSwitchFailure {
    rethrow;
  } on AudioSwitchCancelled {
    rethrow;
  } on AudioRefreshRestoreFailure {
    rethrow;
  } catch (_) {
    check();
  }
  throw const AudioSwitchFailure(false, false);
}
