import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/subtitle_position_memory.dart';
import 'host/start104/position.dart' as current;
import 'host/start104/old_position.dart' as old;
import 'core_test.dart' show syntheticSession;
import 'subtitle_memory102_test.dart' show ScopedRememberedBackend;

class PendingSubtitleBackend104 extends ScopedRememberedBackend {
  bool geometryReady = false;
  @override
  Future<double> readSubtitlePosition({
    required bool Function() allowed,
  }) async {
    if (automatic) {
      if (!geometryReady) throw const SubtitlePositionPending();
      return 18.5;
    }
    return super.readSubtitlePosition(allowed: allowed);
  }

  @override
  Future<double> resetSubtitlePosition({
    required bool Function() allowed,
  }) async {
    automatic = true;
    throw const SubtitlePositionPending();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'complete released103 read starts at screen bottom; current read uses actual authored geometry',
    () async {
      final before = old.PositionReadHarness()
        ..io.values['yingyu-subtitle-position'] = '78.25';
      final after = current.PositionReadHarness()
        ..io.values['yingyu-subtitle-position'] = '78.25';
      expect(await before.readSubtitlePosition(allowed: () => true), 0);
      expect(await after.readSubtitlePosition(allowed: () => true), 21.75);
      expect(after.io.reads, ['yingyu-subtitle-position']);
    },
  );
  test(
    'no displayed bitmap stays unknown, then starts at its real position without writing anything',
    () async {
      final h = current.PositionReadHarness();
      await expectLater(
        h.readSubtitlePosition(allowed: () => true),
        throwsA(isA<SubtitlePositionPending>()),
      );
      expect(h.defaultPosition, isNull);
      h.io.values['yingyu-subtitle-position'] = '84.5';
      expect(await h.readSubtitlePosition(allowed: () => true), 15.5);
      h.io.values.remove('yingyu-subtitle-position');
      expect(
        await h.readSubtitlePosition(allowed: () => true),
        15.5,
        reason:
            'A dialogue gap keeps this same track baseline, not an invented bottom anchor.',
      );
    },
  );
  test(
    'manual screen position and text subtitles retain their established controls',
    () async {
      final manual = current.PositionReadHarness()..manual(32);
      expect(await manual.readSubtitlePosition(allowed: () => true), 32);
      expect(manual.io.reads, isEmpty);
      final text = current.PositionReadHarness()
        ..player.state.subtitle = ['synthetic text'];
      expect(await text.readSubtitlePosition(allowed: () => true), 0);
      expect(text.io.reads, ['sub-pos']);
    },
  );
  test('a retired load cannot cache late authored geometry', () async {
    final h = current.PositionReadHarness();
    final gate = Completer<void>();
    h.io.values['yingyu-subtitle-position'] = '81';
    h.io.onRead = () => gate.future;
    final read = h.readSubtitlePosition(allowed: () => true);
    h.retire();
    gate.complete();
    await expectLater(read, throwsA(isA<AppFailure>()));
    expect(h.defaultPosition, isNull);
  });
  test(
    'failed atomic placement restores its one property and retains subtitle visibility',
    () async {
      final values = {
        'yingyu-subtitle-layout': '-1',
        'sid': '2',
        'sub-visibility': 'yes',
      };
      var rejected = false;
      final writes = <String>[];
      await expectLater(
        writeMpvSubtitleLayout(
          scope: SubtitlePositionScope.discEmbedded,
          position: 30,
          read: (k) async => values[k]!,
          write: (k, v) async {
            writes.add(k);
            if (!rejected) {
              rejected = true;
              values[k] = '-2';
            } else {
              values[k] = v;
            }
          },
          active: () => true,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(values['yingyu-subtitle-layout'], '-1');
      expect(values['sid'], '2');
      expect(values['sub-visibility'], 'yes');
      expect(writes, ['yingyu-subtitle-layout', 'yingyu-subtitle-layout']);
    },
  );
  test(
    'reset with no active bitmap still clears only this resource memory before geometry arrives',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      final api = EmbyClient(
        client: MockClient((_) async => throw StateError('No network allowed')),
      )..session = syntheticSession();
      final backend = PendingSubtitleBackend104()
        ..scope = SubtitlePositionScope.discEmbedded;
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
      session.configureSubtitleViewport(phone: false);
      session.ready = true;
      session.loading = false;
      final target = SubtitlePositionTarget.resolve(
        session.account,
        session.item,
      )!;
      try {
        await session.setSubtitlePosition(35);
        expect(
          store.subtitlePositions.read(
            SubtitleViewport.tablet,
            scope: SubtitlePositionScope.discEmbedded,
            resource: target.key,
          ),
          35,
        );
        await expectLater(
          session.resetSubtitlePosition(),
          throwsA(isA<SubtitlePositionPending>()),
        );
        expect(backend.automatic, true);
        expect(
          store.subtitlePositions.read(
            SubtitleViewport.tablet,
            scope: SubtitlePositionScope.discEmbedded,
            resource: target.key,
          ),
          isNull,
        );
        backend.geometryReady = true;
        expect(await session.readSubtitlePosition(), 18.5);
      } finally {
        await session.close();
        api.close();
        store.log.dispose();
        store.dispose();
      }
    },
  );
}
