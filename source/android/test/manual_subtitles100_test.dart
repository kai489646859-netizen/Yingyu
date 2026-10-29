import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/subtitle_document.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/tracks.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'track_menu_test.dart' show MenuBackend;

class ManualBackend extends MenuBackend {
  bool rejectManual = false;
  @override
  Future<void> subtitle(TrackOption track) async {
    if (rejectManual && track.value is LocalSubtitle) {
      throw const AppFailure('Synthetic subtitle failure');
    }
    await super.subtitle(track);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late EmbyClient api;
  late PlaybackSession session;
  late ManualBackend backend;
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    api = EmbyClient(
      client: MockClient(
        (r) async => r.url.path.endsWith('PlaybackInfo')
            ? response(jsonEncode(playbackData()), 200)
            : r.url.path.contains('Sessions/Playing')
            ? response('', 204)
            : response('{"Id":"movie","Type":"Movie"}', 200),
      ),
    )..session = syntheticSession();
    backend = ManualBackend()..gate.complete();
    session = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
    await session.open();
    directory = await Directory.systemTemp.createTemp('yingyu-test-manual-');
  });
  tearDown(() async {
    await session.close();
    api.close();
    store.log.dispose();
    store.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  Future<SubtitleDocument> document([
    String body = '1\n00:00:01,000 --> 00:00:02,000\nSynthetic',
  ]) async {
    final file = await File(
      '${directory.path}/selected.srt',
    ).writeAsString(body);
    return SubtitleDocument(file.path, 'Synthetic subtitle', 'srt', () async {
      if (await file.exists()) await file.delete();
    }, language: 'zh-cn');
  }

  test(
    'explicit local file changes only subtitle and stays owned until player disposal',
    () async {
      final file = await document(),
          opened = backend.receivedRoute,
          plays = backend.plays,
          rate = session.speed;
      final before = store.prefs
          .getKeys()
          .where((k) => k.contains('track'))
          .toSet();
      await session.attachSubtitle(file);
      expect(session.selectedTrack(true), 'manual-1');
      expect(backend.receivedRoute, same(opened));
      expect(backend.plays, plays);
      expect(session.speed, rate);
      expect(session.continuitySnapshot?.choices[true], isNull);
      expect(
        store.prefs.getKeys().where((k) => k.contains('track')).toSet(),
        before,
      );
      expect(await file.file.exists(), true);
      await session.close();
      expect(await file.file.exists(), false);
    },
  );
  test(
    'subtitle selection failure never becomes a movie error and is still cleaned',
    () async {
      backend.rejectManual = true;
      final file = await document(), old = session.selectedTrack(true);
      await expectLater(
        session.attachSubtitle(file),
        throwsA(isA<AppFailure>()),
      );
      expect(session.error, isNull);
      expect(session.ready, true);
      expect(session.selectedTrack(true), old);
      await session.close();
      expect(await file.file.exists(), false);
    },
  );
  test('late import after close is released before reaching backend', () async {
    final file = await document();
    await session.close();
    await expectLater(session.attachSubtitle(file), throwsA(isA<AppFailure>()));
    expect(await file.file.exists(), false);
  });
  test(
    'empty imported file is released without changing selected subtitle',
    () async {
      final file = await document(''), old = session.selectedTrack(true);
      await expectLater(
        session.attachSubtitle(file),
        throwsA(isA<AppFailure>()),
      );
      expect(session.selectedTrack(true), old);
      expect(session.error, isNull);
      expect(await file.file.exists(), false);
    },
  );
}
