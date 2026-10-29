import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/render_metrics.dart';

void main() {
  for (final (phase, speed) in [2, 3, 2, 3, 2].indexed) {
    test(
      'runtime diagnostics phase $phase at ${speed}x do not dispatch onto a stalled VO thread',
      () async {
        final calls = <String>[];
        var complete = false;
        final gate = Completer<String>();
        final work = readRenderMetrics(
          active: () => true,
          readDisplay: () async => {'modeHz': 60},
          read: (key) async {
            calls.add(key);
            return key == 'vo-passes' ? gate.future : '25';
          },
        );
        work.then((_) => complete = true);
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        final issued = calls.contains('vo-passes');
        final early = complete;
        gate.complete('{"fresh":[]}');
        await work;
        expect(
          issued,
          false,
          reason:
              'optional GPU statistics synchronously dispatch to VO in pinned MPV',
        );
        expect(
          early,
          true,
          reason: 'read-only telemetry must not await the render queue',
        );
      },
    );
  }
}
