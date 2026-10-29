import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/diagnostics.dart';
import 'hdr_warmup106_test.dart' show WarmupFixture;

void main() {
  test(
    'HDR rejection reports preparation and real compatibility restoration',
    () async {
      final stages = <String>[];
      final f = WarmupFixture(onProgress: (stage, detail) => stages.add(stage))
        ..readyAfter = 999999;
      expect(await f.apply(), false);
      expect(
        stages,
        containsAllInOrder([
          'snapshot',
          'hdr-refill',
          'hdr-frame',
          'restore-refill',
          'restore-frame',
        ]),
      );
      expect(f.refills, 2);
      expect(f.output.active, false);
    },
  );

  test(
    'progress observer failure never changes native playback writes',
    () async {
      final silent = WarmupFixture()..readyAfter = 500;
      final observed = WarmupFixture(
        onProgress: (_, _) => throw StateError('UI listener'),
      )..readyAfter = 500;
      expect(await silent.apply(), true);
      expect(await observed.apply(), true);
      expect(observed.writes, silent.writes);
      expect(observed.elapsed, silent.elapsed);
      expect(observed.refills, silent.refills);
    },
  );
  test(
    'waiting samples are bounded and retain separate output stages',
    () async {
      final rows = <String>[];
      final f = WarmupFixture(
        onProgress: (stage, detail) {
          if (stage == 'sample') rows.add(detail);
        },
      )..readyAfter = 999999;
      expect(await f.apply(), false);
      expect(rows.length, lessThanOrEqualTo(11));
      expect(rows.any((r) => r.contains('phase=hdr-frame')), true);
      expect(rows.any((r) => r.contains('phase=restore-frame')), true);
      expect(rows.every((r) => r.length < 1000), true);
      expect(rows.first, contains('video-out-params/w='));
      expect(rows.first, contains('decoder-frame-drop-count='));
    },
  );
  test(
    'user stage labels describe work without claiming premature success',
    () {
      expect(hdrLoadingMessage('snapshot'), '正在校验 HDR 条件');
      expect(hdrLoadingMessage('hdr-frame'), '正在等待 HDR 首帧');
      expect(hdrLoadingMessage('restore-refill'), 'HDR 未就绪，正在恢复兼容画面');
      expect(hdrLoadingMessage('closed-detached'), isNull);
      expect(hdrLoadingMessage('compatible-superseded'), isNull);
    },
  );
  test(
    'fixed decoder warning signatures preserve meaning without raw text',
    () {
      final diagnostics = VideoDiagnostics();
      expect(
        diagnostics.add(
          'ffmpeg/video',
          'error',
          'Both surface and native_window are NULL',
        ),
        contains('未取得 Surface'),
      );
      final line = diagnostics.add(
        'ffmpeg/video',
        'error',
        'Failed to configure codec SECRET with format /private/movie.mkv',
      );
      expect(line, contains('MediaCodec 配置失败'));
      expect(line, isNot(contains('SECRET')));
      expect(line, isNot(contains('/private')));
    },
  );
}
