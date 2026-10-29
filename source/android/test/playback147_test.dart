import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/initial_stream_buffer.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';

void main() {
  test(
    'initial cache enables the existing gate and restores before another route',
    () async {
      final gate = InitialStreamBuffer();
      final values = {'cache-pause-initial': 'no', 'cache-pause-wait': '1.00'};
      final writes = <String>[];
      Future<String> read(String key) async => values[key] ?? '';
      Future<void> write(String key, String value) async {
        writes.add('$key=$value');
        values[key] = value;
      }

      expect(
        await gate.prepare(enabled: true, read: read, write: write),
        isTrue,
      );
      expect(values['cache-pause-wait'], '1.00');
      expect(writes, ['cache-pause-initial=yes']);
      await gate.prepare(enabled: false, read: read, write: write);
      expect(values['cache-pause-initial'], 'no');
      expect(writes, ['cache-pause-initial=yes', 'cache-pause-initial=no']);
    },
  );

  test(
    'failed native write rolls back even when it mutates before failing',
    () async {
      final gate = InitialStreamBuffer();
      var value = 'no';
      Future<String> read(String _) async => value;
      Future<void> write(String _, String next) async {
        value = next;
      if (next == 'yes') {
          throw StateError('native setter failed after mutation');
      }
      }

      expect(
        await gate.prepare(enabled: true, read: read, write: write),
        isFalse,
      );
      expect(value, 'no');
    },
  );

  test(
    'unknown cache state and existing yes do not add writes or timers',
    () async {
      final gate = InitialStreamBuffer();
      var value = '';
      Future<String> read(String _) async => value;
      Future<void> write(String _, String next) async =>
          fail('unexpected write');
      expect(
        await gate.prepare(enabled: true, read: read, write: write),
        isFalse,
      );
      value = 'yes';
      expect(
        await gate.prepare(enabled: true, read: read, write: write),
        isTrue,
      );
      await gate.prepare(enabled: false, read: read, write: write);
    },
  );

  test(
    'backend restores initial state before disc policy then admits only ordinary network',
    () {
      final source = File('lib/playback/backend.dart').readAsStringSync();
      final reset = source.indexOf(
        'enabled: false,',
        source.indexOf("_beginFastBuffer('开播')"),
      );
      final disc = source.indexOf(
        'final cacheSetup = await _discCache.prepare(',
        reset,
      );
      final ordinary = source.indexOf(
        'enabled: _networkFile && _disc == null,',
        disc,
      );
      final load = source.indexOf('await player.open(', ordinary);
      expect(reset, greaterThan(0));
      expect(disc, greaterThan(reset));
      expect(ordinary, greaterThan(disc));
      expect(load, greaterThan(ordinary));
    },
  );

  test(
    'release mode observation accepts fixed fields and rejects arbitrary text',
    () {
      expect(
        pipelineStageMessage(
          'ffmpeg/video',
          'hevc_mediacodec: Yingyu release147 active=1 capacity=2',
        ),
        contains('最多持有2个编号'),
      );
      for (final text in [
        'Yingyu release147 active=2 capacity=2',
        'Yingyu release147 active=1 capacity=3',
        'other: Yingyu release147 active=1 capacity=2',
        'Yingyu release147 active=1 capacity=2 secret',
      ]) {
        expect(pipelineStageMessage('ffmpeg/video', text), isNull);
      }
    },
  );
}
