import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'host/surface073/listeners.dart';

void main() {
  test(
    'queued Surface callbacks configure only the newest native Surface',
    () async {
      final surface = CurrentSurface();
      final entered = Completer<void>(), release = Completer<void>();
      final held = surface.lock.synchronized(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      surface.wid.value = 101;
      final first = surface.widListener();
      surface.wid.value = 102;
      final second = surface.widListener();
      surface.wid.value = 103;
      final third = surface.widListener();
      release.complete();
      await Future.wait([held, first, second, third]);
      expect(
        surface.writes.where((x) => x == 'vo=null'),
        hasLength(1),
        reason:
            'Obsolete callbacks must not destroy and rebuild the newest VO repeatedly',
      );
      expect(surface.writes.where((x) => x.startsWith('wid=')), ['wid=103']);
      expect(surface.player.seeks, isEmpty);
    },
  );

  for (final finalSurface in [0, 321]) {
    test('newest Surface or cleanup is retained: $finalSurface', () async {
      final surface = CurrentSurface();
      final entered = Completer<void>(), release = Completer<void>();
      final held = surface.lock.synchronized(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final pending = <Future<void>>[];
      for (final id in [111, 0, finalSurface]) {
        surface.wid.value = id;
        pending.add(surface.widListener());
      }
      release.complete();
      await Future.wait([held, ...pending]);
      expect(surface.writes.where((x) => x.startsWith('wid=')), [
        'wid=$finalSurface',
      ]);
      expect(surface.writes.last, finalSurface == 0 ? 'vo=null' : 'vo=gpu');
      expect(surface.player.seeks, isEmpty);
    });
  }
  test(
    'an in-flight Surface transaction completes before its replacement',
    () async {
      final surface = GatedSurface();
      surface.wid.value = 111;
      final first = surface.widListener();
      await surface.entered.future;
      surface.wid.value = 222;
      final obsolete = surface.widListener();
      surface.wid.value = 333;
      final latest = surface.widListener();
      surface.release.complete();
      await Future.wait([first, obsolete, latest]);
      expect(surface.writes.where((x) => x.startsWith('wid=')), [
        'wid=111',
        'wid=333',
      ]);
      expect(surface.player.seeks, isEmpty);
    },
  );
  test(
    'real replacements after startup keep their existing frame refresh',
    () async {
      final surface = CurrentSurface();
      await surface.widListener();
      surface.platform.values.addAll({
        'video-frame-info/interlaced': 'no',
        'seeking': 'no',
        'idle-active': 'no',
        'time-pos': '54.25',
      });
      surface.wid.value = 456;
      await surface.widListener();
      expect(surface.player.seeks, [const Duration(milliseconds: 54250)]);
      expect(surface.writes.where((x) => x.startsWith('wid=')), [
        'wid=123',
        'wid=456',
      ]);
    },
  );
}

class GatedSurface extends CurrentSurface {
  final entered = Completer<void>(), release = Completer<void>();
  bool _gate = true;
  @override
  Future<void> setProperty(String key, String value) async {
    if (_gate) {
      _gate = false;
      entered.complete();
      await release.future;
    }
    await super.setProperty(key, value);
  }
}
