import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/diagnostics.dart';

void main() {
  const cases = <String, String>{
    'EGL failed to initialize.': 'EGL显示初始化失败',
    'Could not create EGL surface!': 'EGL窗口表面创建失败',
    'Failed to set context!': 'EGL上下文绑定失败',
    'Could not create EGL context for GLES 2.x +!': 'EGL GLES上下文创建失败',
    'Could not create EGL context for Desktop OpenGL!': 'EGL桌面OpenGL上下文创建失败',
    'Failed to configure context': 'MediaCodec输出格式解析失败',
    'Output MediaFormat is not set': 'MediaCodec未提供输出格式',
    'Output color format is not supported': 'MediaCodec输出颜色格式不支持',
    'Unsupported or unknown profile': 'MediaCodec编码Profile未识别或不支持',
    'P010 negotiation rejected; using compatible output': 'P010协商被拒绝，内核改试兼容输出',
  };
  for (final entry in cases.entries) {
    test('specific native failure is preserved: ${entry.key}', () {
      final video = VideoDiagnostics();
      expect(
        video.add('vo/gpu', 'error', entry.key),
        'vo/error：${entry.value}',
      );
    });
  }

  test('startup codec facts contain only fixed reasons and deduplicate', () {
    final trace = OpeningVideoTrace();
    expect(
      trace.add(
        'ffmpeg/video/hevc_mediacodec',
        'Dolby mapping requires raw GPU output',
      ),
      '当前杜比解码候选未取得原始YUV GPU交接能力',
    );
    expect(
      trace.add('ffmpeg/video', 'Dolby mapping requires raw GPU output'),
      null,
    );
    expect(
      trace.add(
        'vd',
        'Trying hardware decoding via hevc_mediacodec-mediacodec.',
      ),
      '内核正在尝试hevc/mediacodec候选',
    );
    expect(
      trace.add('vd', 'Using software decoding.'),
      '内核正在尝试软件解码候选，最终输出仍需核对',
    );
    trace.clear();
    expect(trace.add('vd', 'Using software decoding.'), isNotNull);
  });
  test(
    'unknown native payloads and wrong origins never enter exported reasons',
    () {
      final trace = OpeningVideoTrace();
      for (final text in [
        'Could not create EGL surface! https://private.invalid/?token=SECRET',
        'Trying hardware decoding via SECRET.',
        'Using software decoding. /private/movie.mkv',
        'Dolby mapping requires raw GPU output token=SECRET',
      ]) {
        expect(trace.add('ffmpeg/video', text), null);
        expect(trace.add('vd', text), null);
      }
      expect(trace.add('stream', 'Using software decoding.'), null);
      expect(
        trace.add('ffmpeg/tcp', 'Dolby mapping requires raw GPU output'),
        null,
      );
    },
  );

  test(
    'pinned FFmpeg item_name prefix preserves the exact rejection reason',
    () {
      final trace = OpeningVideoTrace();
      expect(
        trace.add(
          'ffmpeg/video',
          'hevc_mediacodec: Dolby mapping requires raw GPU output',
        ),
        '当前杜比解码候选未取得原始YUV GPU交接能力',
      );
      expect(
        VideoDiagnostics().add(
          'ffmpeg/video',
          'warn',
          'hevc_mediacodec: P010 negotiation rejected; using compatible output',
        ),
        'ffmpeg/warn：P010协商被拒绝，内核改试兼容输出',
      );
      expect(
        trace.add(
          'ffmpeg/video',
          'private-movie: Dolby mapping requires raw GPU output',
        ),
        null,
      );
      expect(
        trace.add(
          'ffmpeg/video',
          'hevc_mediacodec: Dolby mapping requires raw GPU output token=SECRET',
        ),
        null,
      );
    },
  );
}
