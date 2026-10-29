import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/progress.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/backend.dart' show PlaybackSnapshot;
import 'package:yingyu/playback/tracks.dart';
import 'package:yingyu/playback/track_selection.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'playback_test.dart' show FakeBackend;

MediaItem itemAt(
  int seconds, {
  String date = '2026-10-06T01:00:00Z',
  bool played = true,
}) => MediaItem({
  'Id': 'movie',
  'Type': 'Movie',
  'RunTimeTicks': 91333770000,
  'UserData': {
    'PlaybackPositionTicks': seconds * 10000000,
    'LastPlayedDate': date,
    'Played': played,
    'PlayCount': 3,
    'IsFavorite': true,
  },
});

const off = TrackOption('no', 'off', 'no');
const auto = TrackOption('auto', 'auto', 'auto');
const english = TrackOption(
  '1',
  'English',
  '1',
  language: 'eng',
  codec: 'truehd',
  ffIndex: 2,
  channels: 8,
);
const japanese = TrackOption(
  '2',
  'Japanese',
  '2',
  language: 'jpn',
  codec: 'ac3',
  ffIndex: 7,
  channels: 6,
);
const simplified = TrackOption(
  '1',
  '简体中文',
  '1',
  language: 'chs',
  codec: 'pgs',
  ffIndex: 10,
);
const englishSub = TrackOption(
  '2',
  'English sub',
  '2',
  language: 'eng',
  codec: 'pgs',
  ffIndex: 12,
);
final streams = <Json>[
  {'Type': 'Video', 'Index': 0},
  {
    'Type': 'Audio',
    'Index': 2,
    'Language': 'eng',
    'Codec': 'truehd',
    'Channels': 8,
  },
  {
    'Type': 'Audio',
    'Index': 7,
    'Language': 'jpn',
    'Codec': 'ac3',
    'Channels': 6,
  },
  {
    'Type': 'Subtitle',
    'Index': 10,
    'Language': 'chs',
    'Codec': 'hdmv_pgs_subtitle',
  },
  {'Type': 'Subtitle', 'Index': 12, 'Language': 'eng', 'Codec': 'pgs'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
  });
  for (final remote in [120, 4200, 0]) {
    test(
      'new PC position $remote wins over pending tablet position, even backwards',
      () async {
        final baseline = itemAt(800);
        await store.saveProgress(
          syntheticSession(),
          'movie',
          const Duration(seconds: 900),
          serverBaseline: baseline,
        );
        final fresh = itemAt(remote, date: '2026-10-06T02:00:00Z');
        expect(
          store.resume(syntheticSession(), fresh).position,
          Duration(seconds: remote),
        );
      },
    );
  }
  test(
    'same rejected server state retains unsynchronized local position after restart',
    () async {
      final baseline = itemAt(0);
      await store.saveProgress(
        syntheticSession(),
        'movie',
        const Duration(milliseconds: 151067),
        serverBaseline: baseline,
      );
      final restarted = AppStore(await SharedPreferences.getInstance());
      expect(
        restarted.resume(syntheticSession(), itemAt(0)).position,
        const Duration(milliseconds: 151067),
      );
    },
  );
  test(
    'legacy pending progress does not override a positive PC checkpoint',
    () {
      expect(
        resolveResume(itemAt(50), const Duration(minutes: 40), null).position,
        const Duration(seconds: 50),
      );
      expect(
        resolveResume(itemAt(0), const Duration(seconds: 151), null).position,
        const Duration(seconds: 151),
      );
    },
  );
  test(
    'server-side mark-unwatched is a new state even with the same position',
    () {
      expect(
        resolveResume(
          itemAt(0, played: false),
          const Duration(seconds: 151),
          progressFingerprint(itemAt(0)),
        ).position,
        Duration.zero,
      );
    },
  );
  for (final accept in [true, false]) {
    test(
      '2:31 rejected by playing endpoint: UserData repair accepted=$accept, verified before clearing local',
      () async {
        var saved = itemAt(0);
        final repairs = <Json>[];
        final calls = <String>[];
        final api = EmbyClient(
          client: MockClient((request) async {
            calls.add('${request.method} ${request.url.path}');
            if (request.url.path.endsWith('/PlaybackInfo')) {
              return response(jsonEncode(playbackData()), 200);
            }
            if (request.url.path.contains('/Sessions/Playing')) {
              return response('', 204);
            }
            if (request.url.path.endsWith('/UserData')) {
              repairs.add(object(jsonDecode(request.body)));
              if (accept) {
                saved = MediaItem({
                  ...saved.data,
                  'UserData': jsonDecode(request.body),
                });
              }
              return response('', 204);
            }
            return response(jsonEncode(saved.data), 200);
          }),
        )..session = syntheticSession();
        final backend = FakeBackend()..gate.complete();
        final session = PlaybackSession(
          api: api,
          store: store,
          item: itemAt(0),
          backend: backend,
        );
        await session.open();
        await session.seek(const Duration(milliseconds: 151067));
        await session.close();
        expect(repairs, hasLength(1));
        expect(repairs.single['PlaybackPositionTicks'], 1510670000);
        expect(repairs.single['IsFavorite'], true);
        expect(repairs.single['PlayCount'], 3);
        expect(repairs.single['Played'], true);
        expect(repairs.single['LastPlayedDate'], '2026-10-06T01:00:00Z');
        expect(calls.where((p) => p.endsWith('/PlaybackInfo')), hasLength(1));
        expect(calls.where((p) => p.endsWith('/Configuration')), isEmpty);
        if (accept) {
          expect(session.syncWarning, isNull);
          expect(store.localProgress(api.session!, 'movie'), isNull);
        } else {
          expect(session.syncWarning, contains('Emby 尚未返回相同进度'));
          expect(
            store.localProgress(api.session!, 'movie'),
            const Duration(milliseconds: 151067),
          );
        }
        session.dispose();
        api.close();
      },
    );
  }
  test(
    'normal successful stop never calls the UserData repair endpoint',
    () async {
      var saved = itemAt(0);
      var repairs = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('/Sessions/Playing')) {
            if (request.url.path.endsWith('/Stopped')) saved = itemAt(151);
            return response('', 204);
          }
          if (request.url.path.endsWith('/UserData')) repairs++;
          return response(jsonEncode(saved.data), 200);
        }),
      )..session = syntheticSession();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: saved,
        backend: FakeBackend()..gate.complete(),
      );
      await session.open();
      await session.seek(const Duration(seconds: 151));
      await session.close();
      expect(repairs, 0);
      expect(session.syncWarning, isNull);
      session.dispose();
      api.close();
    },
  );
  test(
    'unsupported UserData endpoint leaves a visible failure and a usable recovery point',
    () async {
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('/Sessions/Playing')) {
            return response('', 204);
          }
          if (request.url.path.endsWith('/UserData')) return response('', 404);
          return response(jsonEncode(itemAt(0).data), 200);
        }),
      )..session = syntheticSession();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: itemAt(0),
        backend: FakeBackend()..gate.complete(),
      );
      await session.open();
      await session.seek(const Duration(seconds: 151));
      await session.close();
      expect(session.syncWarning, contains('404'));
      expect(
        store.resume(api.session!, itemAt(0)).position,
        const Duration(seconds: 151),
      );
      session.dispose();
      api.close();
    },
  );
  test(
    'Emby stream indexes are actual global indexes, never MPV menu ordinals',
    () {
      expect(embyTrackIndex(english, false, streams), 2);
      expect(embyTrackIndex(japanese, false, streams), 7);
      expect(embyTrackIndex(simplified, true, streams), 10);
      expect(embyTrackIndex(off, true, streams), -1);
      expect(embyTrackIndex(off, false, streams), isNull);
      expect(
        embyTrackOption(10, true, [auto, off, simplified, englishSub], streams),
        simplified,
      );
    },
  );
  test(
    'pure STRM with missing tracks or duplicate unknown tracks does not invent a server index',
    () {
      expect(embyTrackIndex(english, false, []), isNull);
      const disc = TrackOption(
        '5',
        '',
        '5',
        language: 'eng',
        codec: 'truehd',
        sourcePid: 4352,
      );
      expect(
        embyTrackIndex(disc, false, [
          ...streams,
          {...streams[1], 'Index': 9},
        ]),
        isNull,
      );
      expect(
        embyTrackOption(500, false, [auto, off, english, japanese], streams),
        isNull,
      );
    },
  );
  test(
    'track choices survive store recreation, server address changes and aliases',
    () async {
      final a = syntheticSession();
      final identity = Session(
        base: a.base,
        userId: a.userId,
        token: a.token,
        username: a.username,
        deviceId: a.deviceId,
        serverId: 'server-a',
      );
      await store.saveTrackChoice(
        identity,
        ['item:movie'],
        false,
        TrackChoice.fromTrack(english),
      );
      final alias = Session(
        base: Uri.parse('https://other-address.invalid'),
        userId: a.userId,
        token: 'new',
        username: a.username,
        deviceId: a.deviceId,
        serverId: 'server-a',
      );
      final restarted = AppStore(await SharedPreferences.getInstance());
      expect(
        restarted.trackChoice(alias, 'item:movie', false)?.resolve([
          const TrackOption(
            '1',
            '',
            '1',
            language: 'en',
            codec: 'TRUEHD',
            channels: 8,
          ),
        ]),
        isNotNull,
      );
    },
  );
  test(
    'resetting a migrated legacy track choice actually removes it',
    () async {
      final a = syntheticSession();
      await store.saveTrackChoice(
        a,
        ['item:movie'],
        true,
        TrackChoice.fromTrack(off),
      );
      final migrated = Session(
        base: a.base,
        userId: a.userId,
        token: a.token,
        username: '',
        deviceId: a.deviceId,
        serverId: 'new-server-id',
      );
      expect(store.trackChoice(migrated, 'item:movie', true), isNotNull);
      await store.saveTrackChoice(migrated, ['item:movie'], true, null);
      expect(store.trackChoice(migrated, 'item:movie', true), isNull);
    },
  );
  test(
    'explicit choice survives restart and every later server default change',
    () async {
      var remote = 2;
      var active = '1';
      final options = [auto, off, english, japanese];
      TrackSelection controller() => TrackSelection(
        store: store,
        account: syntheticSession(),
        itemScope: 'item:movie',
        options: (s) => s ? [auto, off] : options,
        apply: (s, t) async {
          if (!s) active = t.id;
        },
        selected: (s) => s ? 'no' : active,
        onChanged: () {},
        serverDefault: (s) => s ? null : remote,
        serverOption: (s, i) => embyTrackOption(i, s, options, streams),
        serverIndex: (s, t) => embyTrackIndex(t, s, streams),
      );
      final first = controller();
      await first.refresh();
      await first.choose(false, japanese);
      first.close();
      active = '1';
      await controller().refresh();
      expect(active, '2'); // server still stale
      remote = 7;
      await controller().refresh(); // server confirms local Japanese choice
      store = AppStore(await SharedPreferences.getInstance());
      remote = 2;
      active = '2';
      await controller().refresh();
      expect(active, '2'); // Explicit manual Japanese remains selected.
    },
  );
  test(
    'server subtitle off restores across devices; manual simplified still wins this session',
    () async {
      var active = '1';
      final options = [auto, off, simplified, englishSub];
      final c = TrackSelection(
        store: store,
        account: syntheticSession(),
        itemScope: 'item:movie',
        options: (s) => s ? options : [auto, off],
        selected: (s) => s ? active : 'no',
        apply: (s, t) async {
          if (s) active = t.id;
        },
        onChanged: () {},
        serverDefault: (s) => s ? -1 : null,
        serverOption: (s, i) => embyTrackOption(i, s, options, streams),
        serverIndex: (s, t) => embyTrackIndex(t, s, streams),
      );
      await c.refresh();
      expect(active, 'no');
      await c.choose(true, simplified);
      await c.refresh();
      expect(active, '1');
    },
  );
  test(
    'chosen Chinese audio and subtitles survive app restart and changed server defaults together',
    () async {
      const chineseAudio = TrackOption(
        '3',
        '中文配音',
        '3',
        language: 'zho',
        codec: 'ac3',
        channels: 6,
      );
      var activeAudio = '1', activeSub = 'no';
      TrackSelection controller() => TrackSelection(
        store: store,
        account: syntheticSession(),
        itemScope: 'item:movie',
        options: (s) => s
            ? [auto, off, simplified, englishSub]
            : [auto, off, english, chineseAudio],
        selected: (s) => s ? activeSub : activeAudio,
        apply: (s, track) async {
          if (s) {
            activeSub = track.id;
          } else {
            activeAudio = track.id;
          }
        },
        onChanged: () {},
        serverDefault: (s) => s ? 12 : 2,
        serverOption: (s, index) => s ? englishSub : english,
      );
      final first = controller();
      await first.choose(false, chineseAudio);
      await first.choose(true, simplified);
      first.close();
      store = AppStore(await SharedPreferences.getInstance());
      final next = controller();
      await next.refresh();
      expect(activeAudio, '3');
      expect(activeSub, '1');
      // Choosing another subtitle explicitly also beats the simplified default.
      await next.choose(true, englishSub);
      next.close();
      activeAudio = '1';
      activeSub = '1';
      store = AppStore(await SharedPreferences.getInstance());
      final reopened = controller();
      await reopened.refresh();
      expect(activeAudio, '3');
      expect(activeSub, '2');
      reopened.close();
    },
  );
  test(
    'check-in includes mapped indexes and track change event without changing the media URL',
    () async {
      Json? sent;
      final api = EmbyClient(
        client: MockClient((request) async {
          sent = object(jsonDecode(request.body));
          return response('', 204);
        }),
      )..session = syntheticSession();
      await api.report(
        'Progress',
        itemAt(0),
        PlaybackRoute(
          url: 'https://unused.invalid',
          sourceId: 's',
          sessionId: 'p',
          headers: {},
          streams: streams,
        ),
        const Duration(seconds: 42),
        false,
        eventName: 'SubtitleTrackChange',
        audioStreamIndex: 7,
        subtitleStreamIndex: -1,
      );
      expect(sent!['AudioStreamIndex'], 7);
      expect(sent!['SubtitleStreamIndex'], -1);
      expect(sent!['EventName'], 'SubtitleTrackChange');
      expect(sent!['PositionTicks'], 420000000);
      api.close();
    },
  );
  test(
    'missing server userdata never writes default favorite or watched values',
    () async {
      var writes = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          writes++;
          return response('', 204);
        }),
      )..session = syntheticSession();
      await expectLater(
        api.saveResume(
          MediaItem({
            'Id': 'movie',
            'UserData': {'PlaybackPositionTicks': 0},
          }),
          const Duration(seconds: 151),
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(writes, 0);
      api.close();
    },
  );
  test(
    'account changes during readback do not repair the other account',
    () async {
      var stopped = false;
      var repairs = 0;
      final account = syntheticSession();
      late EmbyClient api;
      api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('/Sessions/Playing')) {
            stopped = request.url.path.endsWith('/Stopped');
            return response('', 204);
          }
          if (request.url.path.endsWith('/UserData')) repairs++;
          if (stopped) {
            api.session = Session(
              base: account.base,
              userId: 'other-user',
              token: 'other-synthetic-token',
              username: '',
              deviceId: account.deviceId,
            );
          }
          return response(jsonEncode(itemAt(0).data), 200);
        }),
      )..session = account;
      final session = PlaybackSession(
        api: api,
        store: store,
        item: itemAt(0),
        backend: FakeBackend()..gate.complete(),
      );
      await session.open();
      await session.seek(const Duration(seconds: 151));
      await session.close();
      expect(repairs, 0);
      expect(session.syncWarning, contains('账户已切换'));
      expect(
        store.localProgress(account, 'movie'),
        const Duration(seconds: 151),
      );
      session.dispose();
      api.close();
    },
  );
  test(
    'completed playback keeps the final timestamp and never repairs a cleared resume point',
    () async {
      var repairs = 0;
      Json? stopped;
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('/Sessions/Playing')) {
            if (request.url.path.endsWith('/Stopped')) {
              stopped = object(jsonDecode(request.body));
            }
            return response('', 204);
          }
          if (request.url.path.endsWith('/UserData')) repairs++;
          return response(jsonEncode(itemAt(0).data), 200);
        }),
      )..session = syntheticSession();
      final backend = FakeBackend()..gate.complete();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: itemAt(0),
        backend: backend,
      );
      await session.open();
      await session.seek(const Duration(minutes: 90));
      backend.snapshot = const PlaybackSnapshot(
        completed: true,
        position: Duration(minutes: 90),
        duration: Duration(minutes: 90),
      );
      backend.updates.add(backend.snapshot);
      await Future<void>.delayed(Duration.zero);
      await session.close();
      expect(repairs, 0);
      expect(stopped!['PositionTicks'], 54000000000);
      expect(session.syncWarning, isNull);
      expect(store.localProgress(api.session!, 'movie'), isNull);
      session.dispose();
      api.close();
    },
  );
  for (final kind in ['first-watch', 'opaque-strm']) {
    test(
      '$kind retains simplified subtitles and original audio defaults',
      () async {
        var subtitle = 'no';
        var audio = '1';
        final inventory = kind == 'opaque-strm' ? <Json>[] : streams;
        final controller = TrackSelection(
          store: store,
          account: syntheticSession(),
          itemScope: 'item:movie',
          restoreServerSelection: kind != 'first-watch',
          options: (s) => s
              ? [auto, off, simplified, englishSub]
              : [auto, off, english, japanese],
          selected: (s) => s ? subtitle : audio,
          apply: (s, t) async {
            if (s) {
              subtitle = t.id;
            } else {
              audio = t.id;
            }
          },
          onChanged: () {},
          serverDefault: (s) => s ? -1 : 7,
          serverOption: (s, index) => embyTrackOption(
            index,
            s,
            s
                ? [auto, off, simplified, englishSub]
                : [auto, off, english, japanese],
            inventory,
          ),
          serverIndex: (s, track) => embyTrackIndex(track, s, inventory),
        );
        await controller.refresh();
        expect(subtitle, '1');
        expect(audio, '1');
        controller.close();
      },
    );
  }
}
