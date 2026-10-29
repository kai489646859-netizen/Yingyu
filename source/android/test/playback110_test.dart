import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/playback/player_status.dart';
import 'package:yingyu/playback/tracks.dart';
import 'core_test.dart' show response;
import 'host/disc_clock085/new/backend.dart' as host;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/opening_buffer.dart';
import 'package:yingyu/ui/watch_progress.dart';
import 'core_test.dart' show syntheticSession;
import 'hdr_warmup106_test.dart' show WarmupFixture;

class SeekWarmup extends WarmupFixture {
  final drops = <String>[];
  String filters = '', deinterlace = 'no';
  @override
  Future<String> read(String key) async => switch (key) {
    'hr-seek-framedrop' => options[key] ?? 'no',
    'vf' => filters,
    'deinterlace' => deinterlace,
    _ => await super.read(key),
  };
  @override
  Future<void> refresh(String position) async {
    drops.add(await read('hr-seek-framedrop'));
    await super.refresh(position);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'health sample before native seek starts must not disable seek acceleration',
    () async {
      final h = host.BackendHarness()..start(disc: false);
      h.native.values['hr-seek-framedrop'] = 'no';
      await h.seek(const Duration(seconds: 500));
      expect(h.native.values['hr-seek-framedrop'], 'yes');
      await h.probeAt(1, 500, 500, seeking: false, ready: true);
      expect(
        h.native.values['hr-seek-framedrop'],
        'yes',
        reason:
            'A command acknowledgement precedes the SEEK/restart events; this is still the old frame',
      );
      h.seekEvent();
      await h.probeAt(2, 500, 500, seeking: false, ready: true);
      expect(h.native.values['hr-seek-framedrop'], 'yes');
      h.restartEvent();
      await h.probeAt(3, 500, 500, seeking: false, ready: true);
      expect(h.native.values['hr-seek-framedrop'], 'no');
    },
  );
  for (final kind in [
    'vf',
    'deinterlace',
    'already-enabled',
    'fallback',
    'cancel',
  ]) {
    test('HDR temporary discard respects $kind and cleans up', () async {
      final f = SeekWarmup()..readyAfter = 200;
      if (kind == 'vf') f.filters = '[setpts]';
      if (kind == 'deinterlace') f.deinterlace = 'yes';
      if (kind == 'already-enabled') f.options['hr-seek-framedrop'] = 'yes';
      if (kind == 'fallback') f.readyAfter = 999999;
      if (kind == 'cancel') {
        f.readyAfter = 999999;
        f.cancelAfter = 200;
      }
      await f.apply();
      expect(
        await f.read('hr-seek-framedrop'),
        kind == 'already-enabled' ? 'yes' : 'no',
      );
      expect(
        f.drops.first,
        ['vf', 'deinterlace'].contains(kind) ? 'no' : 'yes',
      );
      expect(
        f.writes.where(
          (e) => ['aid', 'sid', 'pause', 'loadfile'].contains(e.$1),
        ),
        isEmpty,
      );
    });
  }
  testWidgets('charging battery is green while network remains white', (
    tester,
  ) async {
    for (final charging in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerStatusBar(
            data: PlayerStatusData(
              time: DateTime(2026, 10, 20),
              network: 'wifi',
              batteryPercent: 53,
              charging: charging,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final fills = tester
          .widgetList<ColoredBox>(
            find.descendant(
              of: find.byType(PlayerBattery),
              matching: find.byType(ColoredBox),
            ),
          )
          .map((w) => w.color);
      expect(
        fills,
        contains(charging ? const Color(0xFF32D74B) : Colors.white),
      );
      final wifi = find.byIcon(Icons.wifi);
      expect(
        tester.widget<Icon>(wifi).color ??
            IconTheme.of(tester.element(wifi)).color,
        Colors.white,
      );
    }
  });
  test('compact labels retain semantic differences without track IDs', () {
    expect(
      compactAudioTrackLabel(
        language: 'eng',
        codec: 'truehd',
        channels: 8,
        channelLayout: '7.1',
        title: 'English Dolby Atmos 7.1',
      ),
      '英语 · 全景声 · 7.1 声道',
    );
    expect(
      compactAudioTrackLabel(language: 'eng', codec: 'truehd', channels: 8),
      isNot(contains('全景声')),
    );
    expect(
      trackLabel(
        id: '13',
        language: 'zho',
        title: '原盘繁体-TW',
        codec: 'hdmv_pgs_subtitle',
        subtitles: true,
      ),
      '原盘繁体-TW（PGS）',
    );
    expect(
      trackLabel(
        id: '14',
        language: 'zho',
        title: '简英特效',
        codec: 'hdmv_pgs_subtitle',
        subtitles: true,
      ),
      '简英特效（PGS）',
    );
    expect(
      trackLabel(
        id: '15',
        language: 'eng',
        title: 'SDH',
        codec: 'subrip',
        subtitles: true,
      ),
      '英语 · SDH（SRT）',
    );
    expect(
      trackLabel(
        id: '15',
        language: 'und',
        title: '',
        codec: 'subrip',
        subtitles: true,
      ),
      '语言未知（SRT）',
    );
  });
  test(
    'confirmed replay retains watch evidence but never inserts a card into empty live Resume',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      final detail = MediaItem({
        'Id': 'movie',
        'Type': 'Movie',
        'RunTimeTicks': 81772010000,
        'UserData': {'Played': true, 'PlaybackPositionTicks': 8317470000},
      });
      final api = EmbyClient(
        client: MockClient(
          (request) async => response(
            jsonEncode(
              request.url.path.endsWith('/Resume')
                  ? {'Items': []}
                  : detail.data,
            ),
            200,
          ),
        ),
      )..session = syntheticSession();
      var feed = HomeFeed(api, store);
      await feed.afterPlayback(detail, actualCompleted: false);
      expect(feed.resume, isEmpty);
      final progress = WatchProgressState.resolve(detail, api.session, store);
      expect(progress.completed, false);
      expect(progress.fraction, closeTo(831747 / 8177201, 0.000001));
      final evidence = store.watchDisplaySnapshot(api.session!, detail.id);
      final key = feed.cacheKey;
      feed.dispose();
      final cached = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
      for (final row in cached['items'] as List) {
        row['observedAt'] = '2020-01-01T00:00:00Z';
      }
      await prefs.setString(key, jsonEncode(cached));
      feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      expect(feed.resume, isEmpty);
      expect(store.watchDisplaySnapshot(api.session!, detail.id), evidence);
      feed.dispose();
      feed = HomeFeed(api, store);
      expect(feed.resume, isEmpty);
      expect(
        WatchProgressState.resolve(detail, api.session, store).fraction,
        closeTo(831747 / 8177201, 0.000001),
      );
      feed.dispose();
      api.close();
      store.log.dispose();
      store.dispose();
    },
  );
  test('HDR refill uses safe pre-target discard and restores it', () async {
    final f = SeekWarmup()..readyAfter = 200;
    expect(await f.apply(), true);
    expect(f.drops, ['yes']);
    expect(await f.read('hr-seek-framedrop'), 'no');
  });
  test(
    'opening does not require four seconds when native resume gate is one',
    () async {
      var elapsed = Duration.zero;
      final result = await settleOpeningBuffer(
        read: (key) async =>
            {
              'seeking': 'no',
              'paused-for-cache': 'no',
              'demuxer-cache-duration': '1.306000',
              'demuxer-cache-idle': 'no',
              'eof-reached': 'no',
              'cache-pause-wait': '1.000000',
            }[key] ??
            '',
        active: () => true,
        elapsed: () => elapsed,
        wait: (d) async => elapsed += d,
      );
      expect(result, contains('衔接完成'));
      expect(elapsed, lessThanOrEqualTo(const Duration(milliseconds: 600)));
    },
  );
  test(
    'acknowledged positive replay wins over historical Played flag',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final item = MediaItem({
        'Id': 'movie',
        'RunTimeTicks': 81772010000,
        'UserData': {'Played': true, 'PlaybackPositionTicks': 8317470000},
      });
      final state = WatchProgressState.resolve(item, syntheticSession(), store);
      expect(state.fraction, closeTo(831747 / 8177201, 0.000001));
      expect(state.completed, false);
      expect(state.label, contains('13:51'));
      store.log.dispose();
      store.dispose();
    },
  );
}
