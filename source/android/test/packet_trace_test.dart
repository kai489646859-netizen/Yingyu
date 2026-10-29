import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/packet_trace.dart';

void main() {
  test('records fixed MediaCodec numeric messages without codec text', () {
    final t = DiscPacketTrace();
    t.add(
      'ffmpeg/video',
      'trace',
      'hevc_mediacodec: Queued input buffer 3 size=64113 ts=1431096000\n',
    );
    t.add(
      'ffmpeg/video',
      'trace',
      'hevc_mediacodec: Got output buffer 5 offset=0 size=12441600 ts=0 flags=0\n',
    );
    final out = t.finish().join('\n');
    expect(out, contains('pts_us=1431096000'));
    expect(out, contains('pts_us=0'));
    expect(out, isNot(contains('hevc_mediacodec')));
  });
  test('keeps container and timeline layers and missing sentinel distinct', () {
    final t = DiscPacketTrace();
    t.add(
      'demux/lavf',
      'trace',
      'append packet to video: size=1024 '
          'pts=601.500000 dts=601.400000 pos=3456 [num=>1 size=9000]',
    );
    t.add(
      'demux/edl',
      'trace',
      'append packet to video: size=1024 '
          'pts=1.500000 dts=1.400000 pos=3456 [num=1 size=9000]',
    );
    t.add(
      'demux/lavf',
      'trace',
      'append packet to audio: size=123 '
          'pts=-9223372036854775808.000000 dts=602.000000 pos=-1 [num=1 size=123]',
    );
    final out = t.finish().join('\n');
    expect(out, contains('容器/video'));
    expect(out, contains('时间线/video'));
    expect(out, contains('pts_s=-9223372036854775808.000000'));
  });
  test('distinguishes transport tokens, real zero and unknown source PTS', () {
    final t = DiscPacketTrace();
    for (final row in [
      'input token_us=1000 original_us=0 unknown=0 matched=1',
      'output token_us=2000 original_us=0 unknown=1 matched=1',
      'output token_us=3000 original_us=-41708 unknown=0 matched=1',
      'output token_us=0 original_us=0 unknown=1 matched=0',
    ]) {
      t.add(
        'ffmpeg/video',
        'trace',
        'hevc_mediacodec: Yingyu timestamp transport $row',
      );
    }
    final out = t.finish().join('\n');
    expect(out, contains('硬解时间标识/入队'));
    expect(out, contains('硬解时间标识/出队'));
    expect(out, contains('token_us=1000 source_pts_us=0 unknown=0 matched=1'));
    expect(out, contains('token_us=2000 source_pts_us=unknown unknown=1'));
    expect(out, contains('source_pts_us=-41708 unknown=0 matched=1'));
    expect(
      out,
      contains('token_us=0 source_pts_us=unknown unknown=1 matched=0'),
    );
    expect(out, isNot(contains('pts_us=1000')));
    expect(out, isNot(contains('hevc_mediacodec')));
  });
  test('transport diagnostics reject private tails and inconsistent tuples', () {
    final t = DiscPacketTrace();
    for (final row in [
      'input token_us=1 original_us=0 unknown=1 matched=1 PRIVATE',
      'output token_us=1 original_us=0 unknown=1 matched=1\nPRIVATE',
      'input token_us=1 original_us=2 unknown=1 matched=1',
      'output token_us=1 original_us=2 unknown=0 matched=0',
      'input token_us=1 original_us=0 unknown=1 matched=0',
      'output token_us=1 original_us=0 unknown=2 matched=1',
    ]) {
      t.add('ffmpeg/video', 'trace', 'Yingyu timestamp transport $row');
    }
    t.add(
      'ffmpeg/network',
      'trace',
      'Yingyu timestamp transport input token_us=1 original_us=0 unknown=1 matched=1',
    );
    expect(t.finish().length, 1);
    expect(t.finish().join('\n'), isNot(contains('PRIVATE')));
  });
  test('transport observations keep the existing bounded numeric window', () {
    final t = DiscPacketTrace();
    for (var n = 1; n <= 1000; n++) {
      t.add(
        'ffmpeg/video',
        'trace',
        'Yingyu timestamp transport input token_us=$n original_us=0 unknown=1 matched=1',
      );
    }
    final out = t.finish();
    expect(out.length, 18);
    expect(out[1], contains('观察数=1000'));
    expect(out[5], contains('token_us=4 '));
    expect(out[6], contains('token_us=989 '));
    expect(out.last, contains('token_us=1000 source_pts_us=unknown'));
  });
  test('does not persist URLs names raw headers or unmatched text', () {
    final t = DiscPacketTrace();
    for (final s in [
      'https://secret.example/video?api_key=PRIVATE',
      'Queued input buffer 1 size=2 ts=3 PRIVATE',
      'Queued input buffer 1 size=2 ts=3\nPRIVATE',
      'Got output buffer 1 offset=0 size=4 ts=0 flags=0 PRIVATE',
      'PRIVATE: Input packet is missing PTS',
      'Authorization: PRIVATE',
    ]) {
      t.add('ffmpeg/video', 'trace', s);
    }
    expect(t.finish().join('\n'), isNot(contains('PRIVATE')));
    expect(t.finish().join('\n'), isNot(contains('example')));
    expect(t.finish().length, 1);
  });
  test('ignores lookalike records from unrelated prefixes', () {
    final t = DiscPacketTrace();
    t.add('ffmpeg/network', 'trace', 'Queued input buffer 1 size=2 ts=3');
    t.add(
      'secret/demux/lavf',
      'trace',
      'append packet to video: size=1 '
          'pts=2.000000 dts=1.000000 pos=0 [num=1 size=4]',
    );
    expect(t.finish().length, 1);
  });
  test('retains first four and most recent twelve per kind', () {
    final t = DiscPacketTrace();
    for (var n = 0; n < 1000; n++) {
      t.add('ffmpeg/video', 'trace', 'Queued input buffer 0 size=1 ts=$n');
    }
    final out = t.finish();
    expect(out.length, 18);
    expect(out[1], contains('观察数=1000'));
    expect(out[5], endsWith('pts_us=3'));
    expect(out[6], endsWith('pts_us=988'));
    expect(out.last, endsWith('pts_us=999'));
    expect(out.every((line) => line.length < 1200), isTrue);
  });
  test('caps even unrecognized traffic and keeps faults explicit', () {
    final t = DiscPacketTrace();
    t.add(
      'ffmpeg/video',
      'warn',
      'hevc_mediacodec: Input packet is missing PTS',
    );
    t.add(
      'cplayer',
      'warn',
      'Invalid video timestamp: 1431.096000 -> 0.000000',
    );
    t.add('ad', 'error', 'Error decoding audio.');
    t.add('overflow', 'error', 'raw data must not persist');
    for (var n = 0; n < DiscPacketTrace.eventLimit + 10; n++) {
      t.add('unknown', 'trace', 'ignored');
    }
    expect(t.events, DiscPacketTrace.eventLimit);
    expect(t.exhausted, isTrue);
    final out = t.finish().join('\n');
    expect(out, contains('输入缺PTS'));
    expect(out, contains('from_s=1431.096000 to_s=0.000000'));
    expect(out, contains('音频解码错误'));
    expect(out, contains('日志队列溢出'));
    expect(out, isNot(contains('raw data')));
  });
}
