import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/render_metrics.dart';

void main() {
  test('codec workload rows keep only bounded rates and fixed outcomes', () {
    expect(
      codecWorkloadMessage(
        'ffmpeg/video',
        'hevc_mediacodec: Yingyu codec workload request=71.928 result=call-complete\n',
      ),
      contains('请求=71.928 fps；接口调用=完成'),
    );
    expect(
      codecWorkloadMessage(
        'ffmpeg/video',
        'Yingyu codec workload request=48.000 result=unavailable',
      ),
      contains('沿用原播放'),
    );
  });
  test(
    'codec workload parser never swallows arbitrary errors or private text',
    () {
      for (final value in [
        'Could not open codec',
        'Yingyu codec workload request=0.000 result=call-complete',
        'Yingyu codec workload request=1001.000 result=call-complete',
        'Yingyu codec workload request=72.000 result=call-complete\nhttps://private',
        'Yingyu codec workload request=NaN result=call-complete',
        'x' * 181,
      ]) {
        expect(codecWorkloadMessage('ffmpeg/video', value), isNull);
      }
      expect(
        codecWorkloadMessage(
          'network',
          'Yingyu codec workload request=72.000 result=call-complete',
        ),
        isNull,
      );
    },
  );
  test('Android app and physical rates remain separate and numeric', () async {
    final value = await readRenderMetrics(
      includeGpuPasses: true,
      read: (_) async => '60',
      active: () => true,
      readDisplay: () async => {
        'appHz': 120,
        'modeHz': 144,
        'maximumHz': 144,
        'private': 'private display name',
      },
    );
    expect(value, contains('Android应用刷新率=120.000 Hz'));
    expect(value, contains('物理显示模式=144.000 Hz'));
    expect(value, contains('同分辨率可用最高刷新率=144.000 Hz'));
    expect(value, isNot(contains('private')));
  });
  test(
    'Android invalid rates and errors never invent a refresh rate',
    () async {
      for (final rates in [
        null,
        {'appHz': double.nan, 'modeHz': 0, 'maximumHz': -1},
      ]) {
        final value = await readRenderMetrics(
          includeGpuPasses: true,
          read: (_) async => '60',
          active: () => true,
          readDisplay: () async => rates,
        );
        expect(value, contains('未提供'));
        expect(value, isNot(contains('NaN')));
        expect(value, isNot(contains('0.000 Hz')));
      }
    },
  );
  test(
    'render metrics report fixed labels and nanoseconds as milliseconds',
    () async {
      final keys = <String>[];
      final value = await readRenderMetrics(
        includeGpuPasses: true,
        read: (key) async {
          keys.add(key);
          return key == 'vo-passes'
              ? '{"fresh":[{"desc":"output to screen (Yingyu fused gain)","last":1250000,"count":8},{"desc":"arbitrary private path","last":250000,"count":8}],"redraw":[]}'
              : key == 'container-fps'
              ? '23.976024'
              : '120';
        },
        active: () => true,
      );
      expect(keys.length, 4);
      expect(value, contains('container-fps=23.976'));
      expect(value, contains('输出合并=yes'));
      expect(value, contains('渲染阶段数=2'));
      expect(value, contains('合计=1.500 ms'));
      expect(value, isNot(contains('private')));
    },
  );
  test(
    'unavailable, invalid and nonfinite optional values stay unknown',
    () async {
      for (final bad in [
        'NaN',
        'Infinity',
        '-1',
        '0',
        '1001',
        'https://private',
      ]) {
        final value = await readRenderMetrics(
          includeGpuPasses: true,
          read: (_) async => bad,
          active: () => true,
        );
        expect(value, contains('container-fps=未提供'));
        expect(value, contains('GPU阶段计时=未提供'));
        expect(value, isNot(contains('https')));
      }
    },
  );
  test('malformed, excessive and invalid pass data is never logged', () async {
    for (final bad in [
      '[]',
      '{}',
      '[{"last":-1}]',
      '[{"last":"secret"}]',
      'x' * 65537,
    ]) {
      final value = await readRenderMetrics(
        includeGpuPasses: true,
        read: (k) async => k == 'vo-passes' ? bad : '60',
        active: () => true,
      );
      expect(value, contains('GPU阶段计时=未提供'));
      expect(value, isNot(contains('secret')));
    }
  });
  test(
    'cancelled playback discards late diagnostics and stops reads',
    () async {
      var active = true, calls = 0;
      final value = await readRenderMetrics(
        includeGpuPasses: true,
        read: (_) async {
          calls++;
          active = false;
          return '60';
        },
        active: () => active,
      );
      expect(value, isNull);
      expect(calls, 1);
    },
  );
  test('optional native property errors do not fail playback', () async {
    final value = await readRenderMetrics(
      includeGpuPasses: true,
      read: (_) async => throw StateError('private native text'),
      active: () => true,
    );
    expect(value, contains('GPU阶段计时=未提供'));
    expect(value, isNot(contains('private')));
  });
  test(
    'unsupported timers preserve fusion status without claiming zero GPU time',
    () async {
      final value = await readRenderMetrics(
        includeGpuPasses: true,
        read: (k) async => k == 'vo-passes'
            ? '{"fresh":[{"desc":"output to screen (Yingyu fused gain)","last":0,"count":0}],"redraw":[]}'
            : '60',
        active: () => true,
      );
      expect(value, contains('输出合并=yes'));
      expect(value, contains('GPU阶段计时=未提供'));
      expect(value, isNot(contains('0.000 ms')));
    },
  );
}
