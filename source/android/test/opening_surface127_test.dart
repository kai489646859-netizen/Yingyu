import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/opening_surface.dart';

Map<String, String> header() => {
  'path': 'synthetic',
  'vid': 'auto',
  'track-list/count': '1',
  'track-list/0/type': 'video',
  'track-list/0/id': '1',
  'track-list/0/image': 'no',
  'track-list/0/albumart': 'no',
  'track-list/0/demux-w': '3840',
  'track-list/0/demux-h': '2160',
  'track-list/0/demux-rotation': '0',
};

void main() {
  for (final angle in [0, 90, 180, 270]) {
    test(
      'actual parsed display dimensions and rotation $angle prepare before decode',
      () async {
        final values = header()..['track-list/0/demux-rotation'] = '$angle';
        final sizes = <List<int>>[];
        final ok = await prepareOpenedVideoSurface(
          address: 'synthetic',
          read: (k) async => values[k] ?? 'unavailable',
          prepare: (w, h) async {
            sizes.add([w, h]);
            return true;
          },
          active: () => true,
        );
        expect(ok, true);
        expect(
          sizes.single,
          angle == 90 || angle == 270 ? [2160, 3840] : [3840, 2160],
        );
      },
    );
  }
  for (final change in <String, String>{
    'vid': 'no',
    'track-list/count': '65',
    'track-list/0/demux-w': '0',
    'track-list/0/demux-h': '9999999',
    'track-list/0/demux-rotation': '45',
    'track-list/0/image': 'yes',
    'track-list/0/albumart': 'yes',
    'path': 'other',
  }.entries) {
    test(
      'unknown/unsafe header keeps existing path: ${change.key}=${change.value}',
      () async {
        final values = header()..[change.key] = change.value;
        var calls = 0;
        expect(
          await prepareOpenedVideoSurface(
            address: 'synthetic',
            read: (k) async => values[k] ?? 'unavailable',
            prepare: (w, h) async {
              calls++;
              return true;
            },
            active: () => true,
          ),
          false,
        );
        expect(calls, 0);
      },
    );
  }
  test(
    'multiple auto video tracks are ambiguous, explicit ID remains valid',
    () async {
      final values = header()..['track-list/count'] = '2';
      for (final e in header().entries.where(
        (e) => e.key.startsWith('track-list/0/'),
      )) {
        values[e.key.replaceFirst('/0/', '/1/')] = e.value;
      }
      values['track-list/1/id'] = '2';
      var calls = 0;
      Future<bool> run() => prepareOpenedVideoSurface(
        address: 'synthetic',
        read: (k) async => values[k] ?? 'unavailable',
        prepare: (w, h) async {
          calls++;
          return true;
        },
        active: () => true,
      );
      expect(await run(), false);
      expect(calls, 0);
      values['vid'] = '2';
      expect(await run(), true);
      expect(calls, 1);
    },
  );
  test(
    'changed media or chosen video during header reads cannot prepare stale output',
    () async {
      for (final key in ['path', 'vid', 'track-list/0/id']) {
        final values = header();
        var calls = 0, reads = 0;
        final ok = await prepareOpenedVideoSurface(
          address: 'synthetic',
          read: (k) async {
            if (k == key && ++reads == 2) return 'changed';
            return values[k] ?? 'unavailable';
          },
          prepare: (w, h) async {
            calls++;
            return true;
          },
          active: () => true,
        );
        expect(ok, false);
        expect(calls, 0);
      }
    },
  );
  test(
    'optional read/prepare failure and retired load retain normal startup',
    () async {
      final values = header();
      var active = true;
      expect(
        await prepareOpenedVideoSurface(
          address: 'synthetic',
          read: (k) async => throw StateError('unavailable'),
          prepare: (w, h) async => true,
          active: () => true,
        ),
        false,
      );
      expect(
        await prepareOpenedVideoSurface(
          address: 'synthetic',
          read: (k) async => values[k]!,
          prepare: (w, h) async => throw StateError('unavailable'),
          active: () => true,
        ),
        false,
      );
      expect(
        await prepareOpenedVideoSurface(
          address: 'synthetic',
          read: (k) async {
            if (k.endsWith('/demux-h')) active = false;
            return values[k]!;
          },
          prepare: (w, h) async => throw StateError('must not prepare'),
          active: () => active,
        ),
        false,
      );
    },
  );
}
