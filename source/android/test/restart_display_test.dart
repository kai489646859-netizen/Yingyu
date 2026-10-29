// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/watch_progress.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show response, syntheticSession;
import 'home_feed_test.dart' show entry;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late EmbyClient api;
  late MediaItem detail;
  late List<MediaItem> server;
  final feeds = <HomeFeed>[];
  HomeFeed open() {
    final feed = HomeFeed(api, store);
    feeds.add(feed);
    return feed;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    detail = entry('restart', seconds: 0, date: '2026-10-16T02:00:00Z');
    server = [];
    api = EmbyClient(
      client: MockClient(
        (request) async => response(
          jsonEncode(
            request.method == 'POST'
                ? detail.data['UserData']
                : request.url.path.endsWith('/Resume')
                ? {'Items': server.map((item) => item.data).toList()}
                : detail.data,
          ),
          200,
        ),
      ),
    )..session = syntheticSession();
  });
  tearDown(() async {
    for (final feed in feeds) {
      feed.dispose();
    }
    feeds.clear();
    api.close();
    await store.log.flush();
    store.dispose();
  });

  Future<HomeFeed> acknowledgeRestart({bool played = false}) async {
    final baseline = entry('restart', seconds: 120, played: played);
    detail = entry(
      'restart',
      seconds: 0,
      played: played,
      date: '2026-10-16T02:00:00Z',
    );
    await store.saveProgress(
      api.session!,
      detail.id,
      Duration.zero,
      serverBaseline: baseline,
      keepZeroDisplay: true,
    );
    await store.observeProgress(api.session!, detail, Duration.zero);
    await store.confirmProgress(api.session!, detail.id, Duration.zero);
    final feed = open();
    await feed.afterPlayback(detail, actualCompleted: false);
    return feed;
  }

  Future<void> ageRecent(HomeFeed feed) async {
    final saved = object(jsonDecode(store.prefs.getString(feed.cacheKey)!));
    saved['items'] = [
      for (final value in objects(saved['items']))
        {
          ...value,
          'observedAt': DateTime.now()
              .subtract(const Duration(hours: 2))
              .toIso8601String(),
        },
    ];
    await store.prefs.setString(feed.cacheKey, jsonEncode(saved));
  }

  test(
    'acknowledged zero stays durable without resurrecting an empty server Resume',
    () async {
      final feed = await acknowledgeRestart();
      expect(store.localProgress(api.session!, detail.id), isNull);
      expect(store.restartObserved(api.session!, detail), true);
      expect(feed.resume, isEmpty);
      await ageRecent(feed);
      await store.prefs.reload();
      final reopened = open();
      expect(reopened.resume, isEmpty);
      await reopened.refreshResume(force: true);
      expect(reopened.resume, isEmpty);
      expect(object(detail.data['UserData'])['Played'], false);
    },
  );

  test(
    'opening an ordinary zero item does not create a continue-watching row',
    () async {
      await store.saveProgress(
        api.session!,
        detail.id,
        Duration.zero,
        serverBaseline: detail,
      );
      await store.observeProgress(api.session!, detail, Duration.zero);
      await store.confirmProgress(api.session!, detail.id, Duration.zero);
      final feed = open();
      await feed.afterPlayback(detail, actualCompleted: false);
      expect(feed.resume, isEmpty);
      await ageRecent(feed);
      expect(open().resume, isEmpty);
      expect(store.restartObserved(api.session!, detail), false);
    },
  );

  test(
    'server120 display and unsynced zero remain separate across restart',
    () async {
      detail = entry('restart', seconds: 120, date: '2026-10-16T02:00:00Z');
      server = [detail];
      await store.saveProgress(
        api.session!,
        detail.id,
        Duration.zero,
        serverBaseline: detail,
        keepZeroDisplay: true,
      );
      final feed = open();
      await feed.afterPlayback(detail, actualCompleted: false);
      expect(feed.resume.single.resume, const Duration(seconds: 120));
      expect(store.restartObserved(api.session!, feed.resume.single), true);
      expect(store.localProgress(api.session!, detail.id), Duration.zero);
      await ageRecent(feed);
      final reopened = open();
      expect(reopened.resume.single.resume, const Duration(seconds: 120));
      await reopened.refreshResume(force: true);
      expect(reopened.resume.single.resume, const Duration(seconds: 120));
      expect(
        reopened.cachedItems.single.resume,
        const Duration(seconds: 120),
        reason:
            'persist the real server baseline separately from the displayed zero',
      );
      server = [entry('restart', seconds: 20, date: '2026-10-16T03:00:00Z')];
      await reopened.refreshResume(force: true);
      expect(reopened.resume.single.resume, const Duration(seconds: 20));
      expect(store.restartObserved(api.session!, server.single), false);
      expect(
        store.localProgress(api.session!, detail.id),
        Duration.zero,
        reason:
            'display merging never clears or uploads the pending checkpoint',
      );
    },
  );

  test(
    'restart evidence preserves Played=true without claiming completion',
    () async {
      final feed = await acknowledgeRestart(played: true);
      expect(feed.resume, isEmpty);
      expect(object(detail.data['UserData'])['Played'], true);
      expect(store.completions.pending(api.session!, detail.id), false);
      await ageRecent(feed);
      final reopened = open();
      await reopened.refreshResume(force: true);
      expect(reopened.resume, isEmpty);
      expect(store.restartObserved(api.session!, detail), true);
    },
  );

  test(
    'a newer server checkpoint wins over a durable zero observation',
    () async {
      final feed = await acknowledgeRestart();
      server = [entry('restart', seconds: 20, date: '2026-10-16T03:00:00Z')];
      await feed.refreshResume(force: true);
      expect(feed.resume.single.resume, const Duration(seconds: 20));
      expect(store.restartObserved(api.session!, server.single), false);
      await ageRecent(feed);
      final reopened = open();
      await reopened.refreshResume(force: true);
      expect(reopened.resume.single.resume, const Duration(seconds: 20));
    },
  );

  test(
    'a newer episode from another device wins over the old series zero row',
    () async {
      final original = entry('episode-1', seconds: 0, series: 'series');
      detail = original;
      await store.saveProgress(
        api.session!,
        detail.id,
        Duration.zero,
        serverBaseline: detail,
        keepZeroDisplay: true,
      );
      await store.confirmProgress(api.session!, detail.id, Duration.zero);
      final feed = open();
      await feed.afterPlayback(detail, actualCompleted: false);
      server = [
        entry(
          'episode-2',
          seconds: 40,
          series: 'series',
          date: '2026-10-16T03:00:00Z',
        ),
      ];
      await feed.refreshResume(force: true);
      expect(feed.resume.single.id, 'episode-2');
      await ageRecent(feed);
      final reopened = open();
      await reopened.refreshResume(force: true);
      expect(reopened.resume.single.id, 'episode-2');
      expect(reopened.resume.single.resume, const Duration(seconds: 40));
    },
  );

  test('a later normal seek clears only restart evidence', () async {
    await acknowledgeRestart();
    await store.saveProgress(
      api.session!,
      detail.id,
      const Duration(seconds: 90),
      serverBaseline: detail,
    );
    expect(store.restartObserved(api.session!, detail), false);
    expect(
      store.localProgress(api.session!, detail.id),
      const Duration(seconds: 90),
    );
    await store.recordWatchDisplay(
      api.session!,
      detail,
      const Duration(seconds: 90),
      true,
    );
    await store.saveProgress(
      api.session!,
      detail.id,
      const Duration(seconds: 91),
      serverBaseline: detail,
    );
    expect(
      store.rewatchObserved(api.session!, detail),
      true,
      reason:
          'ordinary checkpoints do not erase the existing non-restart rewatch display',
    );
  });

  test(
    'superseded EOF cannot project confirmed 45-second progress to zero after refresh or restart',
    () async {
      await store.completions.remember(api.session!, detail, detail.duration);
      await store.saveProgress(
        api.session!,
        detail.id,
        const Duration(seconds: 45),
        serverBaseline: detail,
      );
      detail = entry('restart', seconds: 45, date: '2026-10-16T03:00:00Z');
      server = [detail];
      await store.observeProgress(
        api.session!,
        detail,
        const Duration(seconds: 45),
      );
      await store.confirmProgress(
        api.session!,
        detail.id,
        const Duration(seconds: 45),
      );
      expect(store.completions.superseded(api.session!, detail.id), true);
      expect(store.localProgress(api.session!, detail.id), isNull);
      final feed = open();
      await feed.afterPlayback(detail, actualCompleted: false);
      expect(feed.resume.single.resume, const Duration(seconds: 45));
      expect(object(feed.resume.single.data['UserData'])['Played'], false);
      await feed.refreshResume(force: true);
      expect(feed.resume.single.resume, const Duration(seconds: 45));
      await ageRecent(feed);
      await store.prefs.reload();
      final reopened = open();
      expect(reopened.resume.single.resume, const Duration(seconds: 45));
      await reopened.refreshResume(force: true);
      expect(reopened.resume.single.resume, const Duration(seconds: 45));
      expect(object(reopened.resume.single.data['UserData'])['Played'], false);
      await store.completions.remember(api.session!, detail, detail.duration);
      await store.saveProgress(
        api.session!,
        detail.id,
        Duration.zero,
        serverBaseline: detail,
        completed: true,
      );
      server = [];
      await reopened.afterPlayback(detail, actualCompleted: true);
      expect(store.completions.superseded(api.session!, detail.id), false);
      expect(reopened.resume, isEmpty);
      await reopened.refreshResume(force: true);
      expect(reopened.resume, isEmpty);
      expect(open().resume, isEmpty);
    },
  );

  test(
    'explicitly hidden zero row stays hidden after refresh and restart',
    () async {
      final feed = await acknowledgeRestart();
      await feed.removeFromResume(detail);
      expect(feed.resume, isEmpty);
      final reopened = open();
      await reopened.refreshResume(force: true);
      expect(reopened.resume, isEmpty);
      expect(
        store.restartObserved(api.session!, detail),
        true,
        reason:
            'hiding is a display exclusion, not a fabricated progress reset',
      );
    },
  );

  test(
    'zero display evidence and cached metadata remain account scoped',
    () async {
      await acknowledgeRestart();
      final account = api.session!;
      api.session = Session(
        base: account.base,
        userId: 'other-user',
        token: 'SYNTHETIC_OTHER',
        username: 'other',
        deviceId: account.deviceId,
        serverId: account.serverId,
      );
      expect(store.restartObserved(api.session!, detail), false);
      final other = open();
      await other.refreshResume(force: true);
      expect(other.resume, isEmpty);
    },
  );

  test(
    'stale same-zero work cannot rewrite or clear the new display evidence',
    () async {
      await acknowledgeRestart();
      final old = detail;
      final evidence = store.watchDisplaySnapshot(api.session!, detail.id);
      detail = entry('restart', seconds: 0, date: '2026-10-16T03:00:00Z');
      await store.saveProgress(
        api.session!,
        detail.id,
        Duration.zero,
        serverBaseline: detail,
        keepZeroDisplay: true,
      );
      await store.recordWatchDisplay(
        api.session!,
        old,
        Duration.zero,
        false,
        expected: evidence,
      );
      await store.observeProgress(
        api.session!,
        old,
        Duration.zero,
        allowed: () => false,
      );
      await store.confirmProgress(
        api.session!,
        old.id,
        Duration.zero,
        allowed: () => false,
      );
      await store.saveProgress(
        api.session!,
        old.id,
        Duration.zero,
        serverBaseline: old,
        allowed: () => false,
      );
      expect(store.localProgress(api.session!, detail.id), Duration.zero);
      expect(store.restartObserved(api.session!, detail), true);
      expect(store.restartObserved(api.session!, old), false);
      final queued = store.recordWatchDisplay(
        api.session!,
        detail,
        Duration.zero,
        false,
        allowed: () => false,
      );
      await queued;
      expect(store.restartObserved(api.session!, detail), true);
    },
  );

  test(
    'background 1543 ms checkpoint is not acknowledged by server zero',
    () async {
      detail = MediaItem({
        ...detail.data,
        'UserData': {...object(detail.data['UserData']), 'IsFavorite': false},
      });
      final calls = <String>[];
      final retryApi = EmbyClient(
        client: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          return response(jsonEncode(detail.data), 200);
        }),
      )..session = api.session;
      addTearDown(retryApi.close);
      const position = Duration(milliseconds: 1543);
      await store.saveProgress(
        api.session!,
        detail.id,
        position,
        serverBaseline: detail,
        keepZeroDisplay: true,
      );
      await store.retryPendingProgress(retryApi, api.session!);
      expect(calls.where((value) => value.contains('/UserData')), hasLength(1));
      expect(store.localProgress(api.session!, detail.id), position);
      expect(store.resume(api.session!, detail).position, position);
      expect(
        store.log.entries.any((line) => line.message.contains('补传已回读确认')),
        false,
      );
    },
  );

  for (final played in [false, true]) {
    testWidgets(
      'server120 bar remains unchanged while local zero is pending, Played=$played',
      (tester) async {
        late MediaItem projected;
        await tester.runAsync(() async {
          detail = entry('restart', seconds: 120, played: played);
          server = [detail];
          await store.saveProgress(
            api.session!,
            detail.id,
            Duration.zero,
            serverBaseline: detail,
            keepZeroDisplay: true,
          );
          final feed = open();
          await feed.afterPlayback(detail, actualCompleted: false);
          projected = feed.resume.single;
        });
        expect(projected.resume, const Duration(seconds: 120));
        expect(store.localProgress(api.session!, detail.id), Duration.zero);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WatchProgress(
                item: projected,
                account: api.session,
                store: store,
              ),
            ),
          ),
        );
        expect(find.textContaining('待同步 Emby'), findsNothing);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          closeTo(120 / projected.duration.inSeconds, 1e-9),
        );
      },
    );

    testWidgets('actual zero progress row has an empty bar, Played=$played', (
      tester,
    ) async {
      await tester.runAsync(() => acknowledgeRestart(played: played));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WatchProgress(
              item: detail,
              account: api.session,
              store: store,
            ),
          ),
        ),
      );
      expect(find.text(played ? '已看完 · 从头重看' : '从头播放'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0,
      );
      expect(object(detail.data['UserData'])['Played'], played);
      final changed = entry(
        'restart',
        seconds: 0,
        played: played,
        date: '2026-10-16T04:00:00Z',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WatchProgress(
              item: changed,
              account: api.session,
              store: store,
            ),
          ),
        ),
      );
      expect(find.text(played ? '已看完' : '未观看'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        played ? 1 : 0,
      );
    });
  }

  testWidgets(
    'new zero rewatch overrides an older pending EOF; a new EOF clears it',
    (tester) async {
      late HomeFeed feed;
      await tester.runAsync(() async {
        await store.completions.remember(api.session!, detail, detail.duration);
        feed = await acknowledgeRestart();
      });
      expect(store.completions.pending(api.session!, detail.id), true);
      expect(feed.resume, isEmpty);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WatchProgress(
              item: detail,
              account: api.session,
              store: store,
            ),
          ),
        ),
      );
      expect(find.text('已看完 · 从头重看 · 待同步 Emby'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0,
      );
      await tester.runAsync(() async {
        await store.completions.remember(api.session!, detail, detail.duration);
        await store.saveProgress(
          api.session!,
          detail.id,
          Duration.zero,
          serverBaseline: detail,
          completed: true,
        );
        await feed.afterPlayback(detail, actualCompleted: true);
      });
      expect(store.restartObserved(api.session!, detail), false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WatchProgress(
              item: detail,
              account: api.session,
              store: store,
            ),
          ),
        ),
      );
      expect(find.text('已看完 · 待同步 Emby'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        1,
      );
    },
  );

  for (final keepRestart in [true, false]) {
    testWidgets(
      'superseded old EOF shows actual 45-second rewatch after ${keepRestart ? 'natural progress' : 'a new seek'} and confirmation',
      (tester) async {
        await tester.runAsync(() async {
          await store.completions.remember(
            api.session!,
            detail,
            detail.duration,
          );
          await acknowledgeRestart();
          await store.saveProgress(
            api.session!,
            detail.id,
            const Duration(seconds: 45),
            serverBaseline: detail,
            keepZeroDisplay: keepRestart,
          );
        });
        expect(store.completions.pending(api.session!, detail.id), true);
        expect(store.completions.superseded(api.session!, detail.id), true);
        Future<void> mount() => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WatchProgress(
                item: detail,
                account: api.session,
                store: store,
              ),
            ),
          ),
        );
        await mount();
        expect(find.textContaining('已看完 · 重看至 00:45'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          45 / 3600,
        );
        await tester.runAsync(() async {
          detail = entry('restart', seconds: 45, date: '2026-10-16T03:00:00Z');
          await store.observeProgress(
            api.session!,
            detail,
            const Duration(seconds: 45),
          );
          await store.confirmProgress(
            api.session!,
            detail.id,
            const Duration(seconds: 45),
          );
        });
        expect(store.localProgress(api.session!, detail.id), isNull);
        await mount();
        expect(find.textContaining('已看完 · 重看至 00:45'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          45 / 3600,
        );
        await tester.runAsync(() async {
          await store.completions.remember(
            api.session!,
            detail,
            detail.duration,
          );
          await store.saveProgress(
            api.session!,
            detail.id,
            Duration.zero,
            serverBaseline: detail,
            completed: true,
          );
        });
        expect(store.completions.superseded(api.session!, detail.id), false);
        await mount();
        expect(find.text('已看完 · 待同步 Emby'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          1,
        );
      },
    );
  }

  testWidgets('zero restart labels render in light and dark themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 310);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fontPath = Platform.environment['YINGYU_TEST_FONT'];
    if (fontPath != null) {
      await (FontLoader('Roboto')..addFont(
            Future.value(
              ByteData.sublistView(File(fontPath).readAsBytesSync()),
            ),
          ))
          .load();
    }
    final plain = entry('plain', seconds: 0);
    final restarted = detail;
    final rewatched = entry('rewatched', seconds: 0, played: true);
    await tester.runAsync(() async {
      await store.recordWatchDisplay(
        api.session!,
        restarted,
        Duration.zero,
        true,
        restart: true,
      );
      await store.recordWatchDisplay(
        api.session!,
        rewatched,
        Duration.zero,
        true,
        restart: true,
      );
    });
    final capture = GlobalKey();
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme(brightness),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final row in [
                      (item: plain, name: '初次打开'),
                      (item: restarted, name: '返回开头'),
                      (item: rewatched, name: '重新观看'),
                    ]) ...[
                      Text(row.name),
                      const SizedBox(height: 8),
                      WatchProgress(
                        item: row.item,
                        account: api.session,
                        store: store,
                      ),
                      const SizedBox(height: 24),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          'build/ui-previews/$appVersion-feature-resume-zero-${brightness.name}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
