import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/menu.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/tracks.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'core_test.dart' show syntheticSession;
import 'track_menu_test.dart' show MenuBackend;

const chapterProperties = {
  'path': 'SYNTHETIC_MEDIA',
  'chapter-list/count': '3',
  'chapter-list/0/time': '0',
  'chapter-list/0/title': '开场',
  'chapter-list/1/time': '60.125',
  'chapter-list/1/title': '真正的章节名',
  'chapter-list/2/time': '120',
  'chapter-list/2/title': '',
  'sub-delay': '0',
  'sid': 'no',
};

class AdjustmentBackend extends MenuBackend
    implements PlaybackChapterBackend, SubtitleDelayBackend {
  final properties = Map.of(chapterProperties);
  final writes = <String>[];
  String chapterOrigin = 'mpv:1';
  List<int>? discTicks;
  int? discDurationTicks;
  String? discOrigin;
  int chapterReads = 0, delayReads = 0, subtitleChanges = 0;
  Duration? sought;
  @override
  Future<List<PlaybackChapter>> readChapters({
    required bool Function() allowed,
  }) {
    chapterReads++;
    return readAvailableChapters(
      read: (key) async => properties[key] ?? '',
      active: allowed,
      duration: snapshot.duration,
      origin: chapterOrigin,
      discTicks: discTicks,
      discDurationTicks: discDurationTicks,
      discOrigin: discOrigin,
    );
  }

  @override
  Future<Duration> readSubtitleDelay({required bool Function() allowed}) {
    delayReads++;
    return readMpvSubtitleDelay(
      read: (key) async => properties[key] ?? '',
      active: allowed,
    );
  }

  @override
  Future<Duration> setSubtitleDelay(
    Duration value, {
    required bool Function() allowed,
  }) => writeMpvSubtitleDelay(
    value: value,
    read: (key) async => properties[key] ?? '',
    write: (key, value) async {
      writes.add(key);
      properties[key] = value;
    },
    active: allowed,
  );
  @override
  Future<void> seek(Duration position) async {
    sought = position;
    await super.seek(position);
  }

  @override
  Future<void> subtitle(TrackOption track) async {
    subtitleChanges++;
    await super.subtitle(track);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<List<PlaybackChapter>> chapters([
    Map<String, String> changes = const {},
  ]) => readMpvChapters(
    read: (key) async => {...chapterProperties, ...changes}[key] ?? '',
    active: () => true,
    duration: const Duration(minutes: 10),
  );
  test(
    'reads real chapter names and exact fractional positions; missing title is explicit',
    () async {
      final result = await chapters();
      expect(result.map((item) => item.title), ['开场', '真正的章节名', '章节 3']);
      expect(result[1].start, const Duration(milliseconds: 60125));
      expect(currentPlaybackChapter(result, const Duration(seconds: 61)), 1);
      expect(currentPlaybackChapter(result, const Duration(seconds: 120)), 2);
      expect(await chapters({'chapter-list/count': '0'}), isEmpty);
    },
  );
  for (final value in ['NaN', 'Infinity', '-1', '601']) {
    test('invalid chapter time $value cannot become a seek target', () async {
      await expectLater(
        chapters({'chapter-list/1/time': value}),
        throwsA(isA<AppFailure>()),
      );
    });
  }
  test(
    'descending chapter times and excessive lists are rejected without fabricated entries',
    () async {
      await expectLater(
        chapters({'chapter-list/2/time': '20'}),
        throwsA(isA<AppFailure>()),
      );
      await expectLater(
        chapters({'chapter-list/count': '4097'}),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test('chapter reads do not publish a retired media generation', () async {
    var active = true;
    await expectLater(
      readMpvChapters(
        read: (key) async {
          if (key == 'chapter-list/1/time') active = false;
          return chapterProperties[key] ?? '';
        },
        active: () => active,
        duration: const Duration(minutes: 10),
      ),
      throwsA(isA<AppFailure>()),
    );
  });
  test('chapter list changes during reading are rejected', () async {
    var paths = 0;
    await expectLater(
      readMpvChapters(
        read: (key) async => key == 'path' && ++paths > 1
            ? 'OTHER_MEDIA'
            : chapterProperties[key] ?? '',
        active: () => true,
        duration: const Duration(minutes: 10),
      ),
      throwsA(isA<AppFailure>()),
    );
  });
  test(
    'MPV real names take precedence over already parsed disc chapters',
    () async {
      final result = await readAvailableChapters(
        read: (key) async => chapterProperties[key] ?? '',
        active: () => true,
        duration: const Duration(minutes: 10),
        origin: 'mpv:4',
        discTicks: [0, 90000],
        discDurationTicks: 180000,
        discOrigin: 'disc:a:42',
      );
      expect(result[1].title, '真正的章节名');
      expect(result[1].start, const Duration(milliseconds: 60125));
      expect(result[1].origin, 'mpv:4');
    },
  );
  test(
    'EDL missing chapters reuse real playlist-relative 90kHz positions',
    () async {
      final result = await readAvailableChapters(
        read: (key) async =>
            key == 'chapter-list/count' ? '0' : chapterProperties[key] ?? '',
        active: () => true,
        duration: const Duration(minutes: 10),
        origin: 'mpv:4',
        discTicks: [0, 5411250, 10800000],
        discDurationTicks: 54000000,
        discOrigin: 'disc:a:42',
      );
      expect(result.map((chapter) => chapter.title), ['章节 1', '章节 2', '章节 3']);
      expect(result[1].start, const Duration(milliseconds: 60125));
      expect(result[1].origin, 'disc:a:42');
      expect(currentPlaybackChapter(result, const Duration(seconds: 90)), 1);
    },
  );
  for (final ticks in [
    [0, -1],
    [0, 54000001],
    [90000, 0],
  ]) {
    test('invalid parsed disc chapters $ticks cannot become targets', () async {
      await expectLater(
        readAvailableChapters(
          read: (key) async =>
              key == 'chapter-list/count' ? '0' : 'SYNTHETIC_MEDIA',
          active: () => true,
          duration: const Duration(minutes: 10),
          origin: 'mpv:4',
          discTicks: ticks,
          discDurationTicks: 54000000,
          discOrigin: 'disc:a:42',
        ),
        throwsA(isA<AppFailure>()),
      );
    });
  }
  test(
    'positive/negative subtitle delay and reset never write subtitle identity',
    () async {
      final values = Map.of(chapterProperties);
      final writes = <String>[];
      for (final delay in [
        const Duration(milliseconds: 100),
        const Duration(milliseconds: -100),
        Duration.zero,
      ]) {
        final actual = await writeMpvSubtitleDelay(
          value: delay,
          read: (key) async => values[key] ?? '',
          write: (key, value) async {
            writes.add(key);
            values[key] = value;
          },
          active: () => true,
        );
        expect(actual, delay);
        expect(values['sid'], 'no');
      }
      expect(writes.toSet(), {'sub-delay'});
      expect(subtitleDelayLabel(const Duration(milliseconds: 100)), '+0.1 秒');
      expect(subtitleDelayLabel(const Duration(milliseconds: -100)), '-0.1 秒');
      expect(subtitleDelayLabel(Duration.zero), '0.0 秒');
    },
  );
  test(
    'ignored subtitle delay writes remain a visible failure and restore original',
    () async {
      final values = Map.of(chapterProperties);
      await expectLater(
        writeMpvSubtitleDelay(
          value: const Duration(seconds: 1),
          read: (key) async => values[key] ?? '',
          write: (key, value) async {
            if (value != '1.0') values[key] = value;
          },
          active: () => true,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(values['sub-delay'], '0.0');
      expect(values['sid'], 'no');
    },
  );
  test(
    'a retired delay write cannot roll an old value into a new media',
    () async {
      var active = true;
      final writes = <String>[];
      await expectLater(
        writeMpvSubtitleDelay(
          value: const Duration(seconds: 1),
          read: (_) async => '0',
          write: (key, value) async {
            writes.add(value);
            active = false;
          },
          active: () => active,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(writes, ['1.0']);
    },
  );

  late AdjustmentBackend backend;
  late PlaybackSession session;
  late EmbyClient api;
  late AppStore store;
  var requests = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    requests = 0;
    api = EmbyClient(
      client: MockClient((_) async {
        requests++;
        throw StateError('No API request expected');
      }),
    )..session = syntheticSession();
    backend = AdjustmentBackend();
    session = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'synthetic'}),
      backend: backend,
    )..ready = true;
    expect(session.account, api.session);
  });
  tearDown(() async {
    await session.close();
    api.close();
    store.log.dispose();
    store.dispose();
  });
  test(
    'chapter selection revalidates and uses the existing exact Session seek',
    () async {
      final list = await session.readChapters();
      await session.seekChapter(list[1]);
      expect(backend.sought, const Duration(milliseconds: 60125));
      expect(backend.chapterReads, 2);
      expect(backend.writes, isEmpty);
      expect(requests, 0);
    },
  );
  test(
    'stale chapter targets are rejected rather than seeking another chapter',
    () async {
      final list = await session.readChapters();
      backend.properties['chapter-list/1/time'] = '80';
      await expectLater(
        session.seekChapter(list[1]),
        throwsA(isA<AppFailure>()),
      );
      expect(backend.sought, isNull);
    },
  );
  test(
    'changing disc playlist rejects the old target even at the same time',
    () async {
      backend.properties['chapter-list/count'] = '0';
      backend.discTicks = [0, 5411250];
      backend.discDurationTicks = 54000000;
      backend.discOrigin = 'disc:a:42';
      final list = await session.readChapters();
      await session.seekChapter(list[1]);
      expect(backend.sought, const Duration(milliseconds: 60125));
      backend.sought = null;
      backend.discOrigin = 'disc:a:43';
      await expectLater(
        session.seekChapter(list[1]),
        throwsA(isA<AppFailure>()),
      );
      expect(backend.sought, isNull);
    },
  );
  test(
    'queued delay steps do not lose updates or enable disabled subtitles',
    () async {
      await Future.wait([
        session.adjustSubtitleDelay(delta: const Duration(milliseconds: 100)),
        session.adjustSubtitleDelay(delta: const Duration(milliseconds: 100)),
      ]);
      expect(
        await session.readSubtitleDelay(),
        const Duration(milliseconds: 200),
      );
      await session.adjustSubtitleDelay(reset: true);
      expect(await session.readSubtitleDelay(), Duration.zero);
      expect(backend.selectedSubtitleId, 'no');
      expect(backend.subtitleChanges, 0);
      expect(backend.writes.toSet(), {'sub-delay'});
      expect(requests, 0);
    },
  );
  test(
    'account changes and closed sessions cannot read or mutate adjustments',
    () async {
      api.session = syntheticSession('https://different.invalid/emby');
      await expectLater(session.readChapters(), throwsA(isA<AppFailure>()));
      await expectLater(
        session.adjustSubtitleDelay(delta: const Duration(seconds: 1)),
        throwsA(isA<AppFailure>()),
      );
      expect(backend.chapterReads, 0);
      expect(backend.writes, isEmpty);
      api.session = session.account;
      await session.close();
      await expectLater(
        session.readSubtitleDelay(),
        throwsA(isA<AppFailure>()),
      );
    },
  );

  for (final scenario in [
    ('chapters', const Size(320, 740), 1.6),
    ('subtitleDelay', const Size(320, 740), 1.6),
    ('chapters', const Size(1280, 800), 1.0),
    ('subtitleDelay', const Size(1280, 800), 1.0),
  ]) {
    final (pane, size, scale) = scenario;
    testWidgets(
      'root opens $pane at $size scale $scale without reopen, network or polling',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showSurface<void>(
                    context,
                    (_) => PlayerMenu(
                      session: session,
                      fit: BoxFit.contain,
                      onToggle: () {},
                      onSeek: (_) {},
                    ),
                    playerMenu: true,
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(pane == 'chapters' ? '章节选择' : '字幕延迟'));
        await tester.pumpAndSettle();
        expect(find.text(pane == 'chapters' ? '章节选择' : '字幕延迟'), findsNothing);
        if (pane == 'chapters') {
          expect(find.text('真正的章节名'), findsOneWidget);
          expect(find.text('01:00.125'), findsOneWidget);
          expect(
            tester.widget<Text>(find.text('开场')).style!.color,
            accentColor(tester.element(find.text('开场'))),
          );
          final reads = backend.chapterReads;
          await tester.pump(const Duration(seconds: 3));
          expect(backend.chapterReads, reads);
          await tester.runAsync(
            () => session.seek(const Duration(seconds: 90)),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<Text>(find.text('真正的章节名')).style!.color,
            accentColor(tester.element(find.text('真正的章节名'))),
          );
          expect(backend.chapterReads, reads);
          await tester.tap(find.text('真正的章节名'));
          await tester.pumpAndSettle();
          expect(backend.sought, const Duration(milliseconds: 60125));
        } else {
          expect(find.text('字幕已关闭，调整不会开启字幕。'), findsOneWidget);
          await tester.scrollUntilVisible(find.text('延后 0.1 秒'), 60);
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.tap(find.text('延后 0.1 秒'));
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.text('当前延迟'), -80);
          await tester.pumpAndSettle();
          expect(find.text('+0.1 秒'), findsOneWidget);
          await tester.scrollUntilVisible(find.text('重置为 0 秒'), 60);
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.tap(find.text('重置为 0 秒'));
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.text('当前延迟'), -80);
          await tester.pumpAndSettle();
          expect(find.text('0.0 秒'), findsOneWidget);
          final reads = backend.delayReads;
          await tester.pump(const Duration(seconds: 3));
          expect(backend.delayReads, reads);
        }
        expect(requests, 0);
        expect(backend.receivedRoute, isNull);
        expect(backend.subtitleChanges, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
