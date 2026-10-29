import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/render_metrics.dart';

void main() {
  test('pinned MPV exposes performance as the whole vo-passes map', () async {
    final calls = <String>[];
    final message = await readRenderMetrics(
      includeGpuPasses: true,
      active: () => true,
      readDisplay: () async => {'appHz': 120, 'modeHz': 120, 'maximumHz': 144},
      read: (key) async {
        calls.add(key);
        if (key == 'container-fps') return '23.976';
        if (key == 'vo-passes') {
          // get_frame_perf / mp_property_vo_passes in pinned command.c emits
          // these two arrays; it rejects a KEY_ACTION for vo-passes/fresh.
          return '{"fresh":[{"desc":"output to screen (Yingyu fused gain)",'
              '"last":1250000,"avg":1200000,"peak":1400000,"count":8,"samples":[1250000]}],'
              '"redraw":[{"desc":"ignored redraw","last":5000000,"count":8}]}';
        }
        throw StateError('Property unavailable');
      },
    );
    expect(message, contains('输出合并=yes'));
    expect(message, contains('末次GPU阶段合计=1.250 ms'));
    expect(calls, contains('vo-passes'));
    expect(calls, isNot(contains('vo-passes/fresh')));
  });
}
