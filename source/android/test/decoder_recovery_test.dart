import 'dart:async';
import 'dart:ffi';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:yingyu/playback/decoder_recovery.dart';
import 'package:yingyu/playback/diagnostics.dart';

VideoOutputState output({
  String vo = 'gpu',
  bool configured = true,
  bool frame = true,
  bool seeking = false,
  String hw = 'no',
}) => VideoOutputState(
  output: vo,
  configured: configured,
  frameAvailable: frame,
  seeking: seeking,
  hardwareDecoder: hw,
);

class Harness {
  VideoOutputState state = output(frame: false);
  final failures = <String>[];
  final recovered = <VideoOutputState>[];
  int reads = 0;
  bool opened = false;
  late final recovery = DecoderRecovery(
    readOutput: () async {
      reads++;
      return state;
    },
    onFailure: failures.add,
    onRecovered: recovered.add,
  );

  void load() {
    opened = false;
    unawaited(
      recovery.beginLoad().then((_) => opened = true).catchError((Object _) {
        return false;
      }),
    );
  }
}

void main() {
  testWidgets(
    'reconfigure after restart still waits for the current first frame',
    (tester) async {
      final h = Harness()..load();
      addTearDown(h.recovery.cancel);
      h.recovery.restarted();
      await tester.pump();
      h.recovery.outputChanged();
      h.recovery.outputChanged();
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.opened, false);
      h.state = output(hw: 'mediacodec-copy');
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.opened, true);
      expect(h.failures, isEmpty);
    },
  );

  testWidgets(
    'reconfigure discards an in-flight frame and reads the new output',
    (tester) async {
      final pending = Completer<VideoOutputState>();
      var reads = 0;
      var ready = false;
      var state = output(frame: false);
      final recovery = DecoderRecovery(
        readOutput: () async => ++reads == 1 ? await pending.future : state,
        onFailure: (_) => fail('unexpected failure'),
        onRecovered: (_) => fail('not a codec recovery'),
      );
      addTearDown(recovery.cancel);
      unawaited(recovery.beginLoad().then((_) => ready = true));
      recovery.restarted();
      recovery.outputChanged();
      pending.complete(output());
      await tester.pump();
      expect(ready, false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(ready, false);
      state = output();
      await tester.pump(const Duration(milliseconds: 100));
      expect(ready, true);
    },
  );

  testWidgets('seek after restart cannot accept the previous frame', (
    tester,
  ) async {
    final h = Harness()..load();
    addTearDown(h.recovery.cancel);
    h.recovery.restarted();
    await tester.pump();
    h.recovery.outputChanged(seeking: true);
    h.state = output();
    await tester.pump(const Duration(seconds: 1));
    expect(h.opened, false);
    h.recovery.outputChanged();
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.opened, false);
    h.recovery.restarted();
    await tester.pump();
    expect(h.opened, true);
  });

  testWidgets(
    'surface dimensions and a software decoder do not prove a frame',
    (tester) async {
      final h = Harness()..load();
      addTearDown(h.recovery.cancel);
      h.recovery.codecFailed('Could not open codec.');
      h.recovery.restarted();
      await tester.pump(const Duration(seconds: 2));
      expect(h.opened, false);
      expect(h.recovered, isEmpty);
      // The 0.1.1 log sequence: Resize, then a second hardware init failure.
      h.recovery.outputChanged();
      h.recovery.codecFailed('Could not open codec.');
      h.state = output();
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.opened, false);
      h.recovery.restarted();
      await tester.pump();
      expect(h.opened, true);
      expect(h.recovered.single.hardwareDecoder, 'no');
      expect(h.failures, isEmpty);
    },
  );

  testWidgets('hardware playback opens without retry or permanent polling', (
    tester,
  ) async {
    final h = Harness()..load();
    addTearDown(h.recovery.cancel);
    h.state = output(hw: 'mediacodec-copy');
    h.recovery.restarted();
    await tester.pump();
    expect(h.opened, true);
    final reads = h.reads;
    await tester.pump(const Duration(minutes: 2));
    expect(h.reads, reads);
    expect(h.recovered, isEmpty);
    expect(h.failures, isEmpty);
  });

  testWidgets('codec failure after opening survives output rebuild', (
    tester,
  ) async {
    final h = Harness()..load();
    addTearDown(h.recovery.cancel);
    h.state = output();
    h.recovery.restarted();
    await tester.pump();
    expect(h.opened, true);
    h.recovery.outputChanged();
    h.recovery.codecFailed('Could not open codec.');
    h.state = output(vo: 'null');
    h.recovery.restarted();
    await tester.pump();
    expect(h.recovered, isEmpty);
    h.state = output();
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.recovered, hasLength(1));
    await tester.pump(const Duration(seconds: 31));
    expect(h.failures, isEmpty);
  });

  testWidgets('repeated errors do not extend recovery forever', (tester) async {
    final h = Harness()..load();
    addTearDown(h.recovery.cancel);
    h.state = output();
    h.recovery.restarted();
    await tester.pump();
    h.state = output(frame: false);
    h.recovery.codecFailed('Could not open codec.');
    await tester.pump(const Duration(seconds: 20));
    h.recovery.codecFailed('Could not open codec.');
    h.recovery.restarted();
    await tester.pump(const Duration(seconds: 10));
    expect(h.failures.single, contains('恢复超时'));
    expect(h.failures.single, contains('Could not open codec.'));
    await tester.pump(const Duration(minutes: 1));
    expect(h.failures, hasLength(1));
    expect(h.recovered, isEmpty);
  });

  testWidgets('startup keeps its existing outer deadline', (tester) async {
    final h = Harness()..load();
    addTearDown(h.recovery.cancel);
    h.recovery.codecFailed('Could not open codec.');
    await tester.pump(const Duration(seconds: 40));
    expect(h.opened, false);
    expect(h.failures, isEmpty);
    h.recovery.cancel();
    await tester.pump();
  });

  testWidgets('a late property reply cannot validate a replaced output', (
    tester,
  ) async {
    final pending = Completer<VideoOutputState>();
    var recovered = 0;
    final recovery = DecoderRecovery(
      readOutput: () => pending.future,
      onFailure: (_) => fail('unexpected failure'),
      onRecovered: (_) => recovered++,
    );
    addTearDown(recovery.cancel);
    var ready = false;
    unawaited(recovery.beginLoad().then((_) => ready = true));
    recovery.restarted();
    recovery.outputChanged();
    recovery.codecFailed('Could not open codec.');
    pending.complete(output());
    await tester.pump();
    expect(ready, false);
    expect(recovered, 0);
    recovery.restarted();
    await tester.pump();
    expect(ready, true);
    expect(recovered, 1);
  });

  testWidgets('cancel removes waiting and late callbacks after exit', (
    tester,
  ) async {
    final h = Harness()..load();
    h.recovery.codecFailed('Could not open codec.');
    h.recovery.cancel();
    h.state = output();
    h.recovery.restarted();
    await tester.pump(const Duration(minutes: 2));
    expect(h.opened, false);
    expect(h.recovered, isEmpty);
    expect(h.failures, isEmpty);
    expect(h.reads, 0);
  });

  testWidgets('a new load cannot reuse an earlier restart or recovery timer', (
    tester,
  ) async {
    final h = Harness()..load();
    addTearDown(h.recovery.cancel);
    h.state = output();
    h.recovery.restarted();
    await tester.pump();
    h.recovery.codecFailed('Could not open codec.');
    h.load();
    await tester.pump(const Duration(seconds: 31));
    expect(h.opened, false);
    expect(h.failures, isEmpty);
    h.recovery.restarted();
    await tester.pump();
    expect(h.opened, true);
  });

  testWidgets('pause and seek without codec error do not create a failure', (
    tester,
  ) async {
    final h = Harness()..load();
    addTearDown(h.recovery.cancel);
    h.state = output();
    h.recovery.restarted();
    await tester.pump();
    h.recovery.outputChanged();
    h.state = output(seeking: true);
    await tester.pump(const Duration(minutes: 2));
    expect(h.failures, isEmpty);
    expect(h.opened, true);
  });

  test('a frame must belong to a real configured output and live decoder', () {
    for (final state in [
      output(vo: ''),
      output(vo: 'null'),
      output(configured: false),
      output(frame: false),
      output(seeking: true),
      output(hw: ''),
    ]) {
      expect(state.ready, false);
    }
    expect(output().ready, true);
    expect(output(hw: 'mediacodec-copy').ready, true);
  });

  test('terminal native errors are copied and normal endings remain normal', () {
    // Only synthetic FFI structs; no Player, native library or media is loaded.
    final event = calloc<mpv.mpv_event>();
    final end = calloc<mpv.mpv_event_end_file>();
    try {
      event.ref.event_id = mpv.mpv_event_id.MPV_EVENT_END_FILE;
      event.ref.data = end.cast<Void>();
      for (final reason in [
        mpv.mpv_end_file_reason.MPV_END_FILE_REASON_EOF,
        mpv.mpv_end_file_reason.MPV_END_FILE_REASON_STOP,
        mpv.mpv_end_file_reason.MPV_END_FILE_REASON_QUIT,
        mpv.mpv_end_file_reason.MPV_END_FILE_REASON_REDIRECT,
      ]) {
        end.ref.reason = reason;
        end.ref.error = -13;
        expect(NativePlaybackEvent.copy(event)!.failed, false);
      }
      end.ref.reason = mpv.mpv_end_file_reason.MPV_END_FILE_REASON_ERROR;
      final copied = NativePlaybackEvent.copy(event)!;
      end.ref.reason = mpv.mpv_end_file_reason.MPV_END_FILE_REASON_STOP;
      end.ref.error = 0;
      expect(copied.failed, true);
      expect(copied.error, -13);
    } finally {
      calloc.free(end);
      calloc.free(event);
    }
  });

  test('native reconfigure seek and restart signals keep their meanings', () {
    final event = calloc<mpv.mpv_event>();
    try {
      for (final id in [
        mpv.mpv_event_id.MPV_EVENT_VIDEO_RECONFIG,
        mpv.mpv_event_id.MPV_EVENT_SEEK,
      ]) {
        event.ref.event_id = id;
        expect(NativePlaybackEvent.copy(event)!.outputChanged, true);
        expect(NativePlaybackEvent.copy(event)!.restarted, false);
      }
      event.ref.event_id = mpv.mpv_event_id.MPV_EVENT_PLAYBACK_RESTART;
      expect(NativePlaybackEvent.copy(event)!.restarted, true);
      event.ref.event_id = mpv.mpv_event_id.MPV_EVENT_LOG_MESSAGE;
      expect(NativePlaybackEvent.copy(event), isNull);
    } finally {
      calloc.free(event);
    }
  });

  test('all existing error sources retain their original classification', () {
    for (final prefix in ['file', 'vd', 'ad', 'cplayer', 'stream']) {
      expect(isMpvErrorLog(prefix, 'error', 'failure'), true);
      expect(isMpvErrorLog(prefix, 'warn', 'failure'), false);
    }
    expect(isMpvErrorLog('ffmpeg', 'error', 'tcp: failure'), true);
    expect(isMpvErrorLog('ffmpeg', 'error', 'metadata'), false);
    expect(isMpvErrorLog('unrelated', 'error', 'failure'), false);
    expect(decoderMayFallback('Failed to open'), false);
    expect(decoderMayFallback('Error while decoding frame!'), false);
  });
}
