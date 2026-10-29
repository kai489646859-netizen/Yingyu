import 'package:flutter_test/flutter_test.dart';
import 'hdr_refill103_test.dart' show RefillFixture;

// The pinned MPV VO option callback rebuilds the selected decoder even for
// vo=null. Model that real callback ordering, not Android driver performance.
class TransitionFixture extends RefillFixture {
  int nullDecoders = 0, gpuDecoders = 0;
  bool failDisable = false;
  bool lazyRenderer = true;
  String pause = 'yes', audio = '1';
  @override
  Future<String> read(String key) async {
    if (key == 'pause') return pause;
    if (key == 'aid') return audio;
    if (key == 'vid') return selected ? '1' : 'no';
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (key == 'vid' && value == 'no' && failDisable) {
      throw StateError('video detach refused');
    }
    await super.write(key, value);
    if (key == 'vid') {
      selected = value != 'no';
      if (selected && options['vo'] == 'gpu') {
        final rejected = options['gpu-context']!.startsWith('android-hdr')
            ? rejectHdr
            : rejectCompatible;
        actual = rejected ? '' : 'gpu';
      }
    }
    if (lazyRenderer && key == 'vo' && value == 'gpu' && !selected) {
      actual = 'null';
    }
    if (key == 'vo' && selected) {
      if (value == 'null') nullDecoders++;
      if (value == 'gpu') gpuDecoders++;
    }
    if (key == 'vid' && selected && actual == 'gpu') gpuDecoders++;
  }
}

void main() {
  for (final a in ['no', '']) {
    test('video-only or unknown audio retains video selection: $a', () async {
      final f = TransitionFixture()..audio = a;
      expect(await f.apply(), true);
      expect(f.writes.where((e) => e == ('vid', 'no')), isEmpty);
    });
  }
  test('active playback never disables its selected video', () async {
    final f = TransitionFixture()..pause = 'no';
    expect(await f.apply(), true);
    expect(f.writes.where((e) => e == ('vid', 'no')), isEmpty);
  });
  test(
    'real HDR and compatible failure stays an error with progress intact',
    () async {
      final f = TransitionFixture()
        ..rejectHdr = true
        ..rejectCompatible = true;
      await expectLater(f.apply(), throwsStateError);
      expect(f.position, '696.820000');
      expect(f.output.active, true);
    },
  );

  test('HDR transition never creates a decoder for the null output', () async {
    final f = TransitionFixture();
    expect(await f.apply(), true);
    expect(
      f.nullDecoders,
      0,
      reason:
          'The intermediate null VO must not create and tear down MediaCodec',
    );
    expect(f.options['vid'], 'auto');
    expect(f.refreshes, ['696.820000']);
    expect(
      f.writes.where((e) => ['pause', 'aid', 'sid', 'loadfile'].contains(e.$1)),
      isEmpty,
    );
  });
  test(
    'rejected HDR restores video selection and real compatible frame',
    () async {
      final f = TransitionFixture()..rejectHdr = true;
      expect(await f.apply(), false);
      expect(f.nullDecoders, 0);
      expect(f.options['vid'], 'auto');
      expect(f.selected, true);
      expect(f.frame, true);
      expect(f.output.active, false);
    },
  );
}
