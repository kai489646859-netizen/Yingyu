import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'host/output127/android.dart';

void main() {
  test(
    'ordinary same-size callback keeps its original behavior without preparation',
    () async {
      final h = AndroidHarness();
      h.rect.value = Rect.fromLTWH(0, 0, 3840, 2160);
      await h.parameters(const VideoParams(dw: 3840, dh: 2160, rotate: 0));
      expect(h.waitUntilFirstFrameRenderedCompleter.isCompleted, false);
      expect(h.channel.calls, 0);
      expect(h.writes, isEmpty);
    },
  );
  test(
    'published Surface with unconfirmed VO still accepts later real decoded parameters',
    () async {
      final h = AndroidHarness();
      h.platform.readOverrides['vo'] = 'unavailable';
      expect(await h.prepareVideoSurface(3840, 2160), false);
      expect(h.waitUntilFirstFrameRenderedCompleter.isCompleted, false);
      await h.parameters(const VideoParams(dw: 3840, dh: 2160, rotate: 0));
      expect(h.waitUntilFirstFrameRenderedCompleter.isCompleted, true);
      expect(h.player.seeks, isEmpty);
    },
  );
  test('retired preload cannot publish its late native snapshot', () async {
    final h = AndroidHarness();
    var active = true;
    h.channel.beforeReply = () {
      active = false;
    };
    expect(await h.prepareVideoSurface(3840, 2160, () => active), false);
    expect(h.wid.value, isNull);
    expect(h.writes, isEmpty);
  });
  test('concurrent preparation coalesces without losing its owner', () async {
    final h = AndroidHarness();
    final result = await Future.wait([
      h.prepareVideoSurface(3840, 2160),
      h.prepareVideoSurface(3840, 2160),
    ]);
    expect(result, [true, false]);
    expect(h.channel.calls, 1);
  });
  test('optional native failure releases preparation ownership', () async {
    final h = AndroidHarness();
    h.channel.reply = null;
    expect(await h.prepareVideoSurface(3840, 2160), false);
    h.channel.reply = {'id': 1, 'wid': 20, 'width': 3840, 'height': 2160};
    expect(await h.prepareVideoSurface(3840, 2160), true);
  });
  test(
    'mapped Dolby retains gpu-next and an active native HDR owner is untouched',
    () async {
      final mapped = AndroidHarness()..mapped = true;
      expect(await mapped.prepareVideoSurface(3840, 2160), true);
      expect(mapped.platform.values['vo'], 'gpu-next');
      final hdr = AndroidHarness()..hdr = true;
      expect(await hdr.prepareVideoSurface(3840, 2160), false);
      expect(hdr.channel.calls, 0);
      expect(hdr.writes, isEmpty);
    },
  );
  test(
    'first decoded size correction does not refresh an unseen prepared frame',
    () async {
      final h = AndroidHarness();
      expect(await h.prepareVideoSurface(3840, 2160), true);
      h.platform.values.addAll({
        'video-frame-info/interlaced': 'no',
        'seeking': 'no',
        'idle-active': 'no',
        'time-pos': '0',
      });
      h.channel.onResize = () {
        h.wid.value = 33;
      };
      await h.parameters(const VideoParams(dw: 1920, dh: 1080, rotate: 0));
      await h.lock.synchronized(() async {});
      await Future<void>.delayed(Duration.zero);
      expect(
        h.player.seeks,
        isEmpty,
        reason:
            'Preparing a Surface must not create a new initial seek when actual decoded size differs',
      );
    },
  );
  for (final callbackFirst in [false, true]) {
    test(
      'acknowledged first Surface reaches MPV before decode: callback first=$callbackFirst',
      () async {
        final h = AndroidHarness();
        if (callbackFirst) {
          h.channel.beforeReply = () {
            h.rect.value = Rect.fromLTWH(0, 0, 3840, 2160);
            h.wid.value = 20;
          };
        }
        expect(await h.prepareVideoSurface(3840, 2160), true);
        expect(h.writes.where((x) => x == 'vo=null'), hasLength(1));
        expect(h.platform.values['wid'], '20');
        expect(h.platform.values['vo'], 'gpu');
        expect(h.player.seeks, isEmpty);
        expect(h.waitUntilFirstFrameRenderedCompleter.isCompleted, false);
        final before = List.of(h.writes);
        await h.parameters(const VideoParams(dw: 3840, dh: 2160, rotate: 0));
        expect(h.waitUntilFirstFrameRenderedCompleter.isCompleted, true);
        expect(
          h.writes,
          before,
          reason: 'same decoded size must not rebuild the prepared output',
        );
        expect(await h.prepareVideoSurface(3840, 2160), false);
        expect(
          h.channel.calls,
          1,
          reason: 'a working/sized Surface retains its established path',
        );
      },
    );
  }
  test(
    'close while native preparation replies does not resurrect output',
    () async {
      final h = AndroidHarness()..channel.beforeReply = null;
      h.channel.beforeReply = h.close;
      expect(await h.prepareVideoSurface(3840, 2160), false);
      expect(h.wid.value, isNull);
      expect(h.writes, isEmpty);
    },
  );
  for (final replacement in [0, 33]) {
    test(
      'cleanup or newer Surface wins over stale preparation snapshot: $replacement',
      () async {
        final h = AndroidHarness();
        h.channel.beforeReply = () {
          h.rect.value = Rect.fromLTWH(0, 0, 3840, 2160);
          h.wid.value = replacement;
        };
        expect(await h.prepareVideoSurface(3840, 2160), false);
        await h.lock.synchronized(() async {});
        expect(h.wid.value, replacement);
        expect(h.writes.where((x) => x == 'wid=20'), isEmpty);
      },
    );
  }
  test(
    'phone/screen canvas remains authoritative over parsed movie size',
    () async {
      final h = AndroidHarness()..phone(2560, 1600);
      h.channel.reply = {'id': 1, 'wid': 20, 'width': 2560, 'height': 1600};
      expect(await h.prepareVideoSurface(3840, 2160), true);
      expect(h.platform.values['android-surface-size'], '2560x1600');
    },
  );
  test(
    'invalid or missing native snapshot does not claim prepared output',
    () async {
      for (final reply in [
        null,
        {'id': 1, 'wid': 0, 'width': 3840, 'height': 2160},
        {'id': 1, 'wid': 20, 'width': 1, 'height': 1},
      ]) {
        final h = AndroidHarness();
        h.channel.reply = reply;
        expect(await h.prepareVideoSurface(3840, 2160), false);
        expect(h.writes, isEmpty);
      }
    },
  );
}
