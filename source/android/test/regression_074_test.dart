import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/audio_decode_watch.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_ordered_reader.dart';
import 'package:yingyu/playback/info.dart';
import 'package:yingyu/playback/runtime_health.dart';
import 'host/replay074/audio_decode_watch.dart' as old_audio;
import 'host/replay074/home_feed.dart' as old_home;
import 'host/replay074/disc_ordered_reader.dart' as old_reader;
import 'core_test.dart' show syntheticSession, response;
import 'disc_ordered_reader_test.dart' show Source, until, mib, chunk;
import 'runtime_health_test.dart' show sample;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'old audio deadline preempts video repair; current keeps bounded repair and verifies fresh A/V',
    () {
      final before = old_audio.AudioDecodeWatch()
        ..fault(Duration.zero, playing: true);
      final after = AudioDecodeWatch()..fault(Duration.zero, playing: true);
      final video = RuntimeHealthWatch();
      for (final second in [0, 2, 4, 6]) {
        final value = sample(second, 0, second + 8);
        before.sample(value);
        after.sample(value);
        final action = video.sample(value, speed: 1);
        if (action == RuntimeAction.recover) {
          video.beginRecovery(
            const Duration(seconds: 7),
            value.now,
            hardware: 'mediacodec-copy',
          );
        }
      }
      expect(video.recovering, true);
      final waiting = sample(8, 0, 16, buffering: true, seeking: true);
      expect(before.sample(waiting), old_audio.AudioDecodeAction.fail);
      expect(
        after.sample(waiting, videoRecovering: video.recovering),
        AudioDecodeAction.none,
      );
      expect(after.pending, true);
      after.sample(sample(10, 7, 7), videoRecovering: true);
      expect(
        after.sample(sample(12, 9, 9), videoRecovering: true),
        AudioDecodeAction.verified,
      );
      expect(after.pending, false);
    },
  );
  test(
    'video repair does not hide persistent audio faults or extend the video deadline',
    () {
      final audio = AudioDecodeWatch()..fault(Duration.zero, playing: true);
      final video = RuntimeHealthWatch()
        ..beginRecovery(
          const Duration(seconds: 7),
          Duration.zero,
          hardware: 'mediacodec-copy',
        );
      for (final second in [0, 10, 20, 30]) {
        final value = sample(second, 0, second + 8, buffering: true);
        expect(
          audio.sample(value, videoRecovering: video.recovering),
          AudioDecodeAction.none,
        );
        final result = video.sample(value, speed: 1);
        expect(result, second == 30 ? RuntimeAction.fail : RuntimeAction.none);
      }
      // Buffering no longer spends the independent audio playback budget.
      expect(audio.sample(sample(31, 0, 39)), AudioDecodeAction.none);
      expect(audio.sample(sample(39, 0, 47)), AudioDecodeAction.fail);
      for (var n = 0; n < 8; n++) {
        audio.fault(const Duration(seconds: 40), playing: true);
      }
      expect(
        audio.sample(sample(40, 0, 0), videoRecovering: true),
        AudioDecodeAction.fail,
      );
    },
  );
  for (final previous in [true, false]) {
    test(
      'queued browsing pause preserves rows and resumes automatically: old=$previous',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        final api = EmbyClient(
          client: MockClient(
            (request) async => response(
              jsonEncode(
                request.url.path.endsWith('/Views')
                    ? {
                        'Items': [
                          {'Id': 'lib', 'Name': '合成媒体库'},
                        ],
                      }
                    : request.url.path.endsWith('/Latest')
                    ? [
                        {'Id': 'fresh', 'Name': '刷新后的合成项目'},
                      ]
                    : {'Items': []},
              ),
              200,
            ),
          ),
        )..session = syntheticSession();
        final dynamic feed = previous
            ? old_home.HomeFeed(api, store)
            : HomeFeed(api, store);
        final library = MediaItem({'Id': 'lib', 'Name': '合成媒体库'});
        final cached = MediaItem({'Id': 'cached', 'Name': '已显示的项目'});
        final dynamic section = previous
            ? old_home.HomeSection(library, items: [cached])
            : HomeSection(library, items: [cached]);
        final owner = Object();
        api.backgroundWork.pause(owner, true);
        await feed.loadSection(section, feed.generation);
        expect(section.items.single.id, 'cached');
        expect(section.error, previous ? '浏览任务已暂停' : null);
        api.backgroundWork.pause(owner, false);
        if (!previous) {
          await until(
            () =>
                feed.sections.isNotEmpty &&
                feed.sections.first.items.isNotEmpty,
          );
          expect(feed.sections.first.items.single.id, 'fresh');
          expect(feed.sections.first.error, isNull);
        }
        feed.dispose();
        api.close();
        store.dispose();
      },
    );
    test(
      'seek to received-prefix boundary keeps one media response: old=$previous',
      () async {
        final source = Source();
        final dynamic reader = previous
            ? old_reader.DiscOrderedReader(source.open, maxBytes: 2 * mib)
            : DiscOrderedReader(source.open, maxBytes: 2 * mib);
        try {
          await reader.read(
            '',
            0,
            mib,
            DiscReadCancellation(),
            availableOnly: true,
          );
          await until(() => source.received == mib);
          final block = await reader.read(
            '',
            mib,
            chunk,
            DiscReadCancellation(),
          );
          expect(block.bytes[0], 16);
          expect(source.opens, previous ? 2 : 1);
          expect(source.peak, 1);
        } finally {
          await reader.close();
        }
      },
    );
  }
  test(
    'resource type uses current transport, selected source or known container only',
    () {
      PlaybackRoute route({DiscKind kind = DiscKind.none}) => PlaybackRoute(
        url: 'https://synthetic.invalid/file',
        sourceId: 'chosen',
        sessionId: '',
        headers: {},
        streams: [],
        discKind: kind,
      );
      expect(
        playbackResourceType(
          confirmedDisc: 'ISO',
          route: route(),
          metadata: {'Container': 'strm'},
          format: 'edl',
        ),
        'ISO',
      );
      expect(
        playbackResourceType(
          confirmedDisc: '',
          route: route(kind: DiscKind.blurayFolder),
          metadata: {},
        ),
        'BDMV',
      );
      expect(
        playbackResourceType(
          confirmedDisc: '',
          route: route(),
          metadata: {
            'MediaSources': [
              {'Id': 'other', 'Container': 'iso'},
              {'Id': 'chosen', 'Container': 'mkv'},
            ],
          },
        ),
        'MKV',
      );
      expect(
        playbackResourceType(
          confirmedDisc: '',
          route: route(),
          metadata: {'Name': '假的.iso'},
          format: 'mpegts',
        ),
        'MPEG-TS',
      );
      expect(
        playbackResourceType(
          confirmedDisc: '',
          route: route(),
          metadata: {
            'MediaSources': [
              {'Id': 'chosen', 'Container': 'strm'},
            ],
          },
        ),
        '封装格式未识别',
      );
    },
  );
}
