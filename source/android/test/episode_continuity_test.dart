import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/episode_continuity.dart';
import 'package:yingyu/playback/tracks.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

const auto = TrackOption('auto', '自动', 'auto');
const off = TrackOption('no', '关闭', 'no');
TrackOption sub(String id, String language) =>
    TrackOption(id, language, id, language: language, codec: 'srt');
TrackOption audio(String id, String language) => TrackOption(
  id,
  language,
  id,
  language: language,
  codec: 'aac',
  channels: 2,
);

class ContinuousBackend extends FakeBackend implements TrackStateBackend {
  ContinuousBackend(this.subs, this.audios) {
    gate.complete();
  }
  final List<TrackOption> subs, audios;
  @override
  List<TrackOption> get subtitleTracks => [auto, off, ...subs];
  @override
  List<TrackOption> get audioTracks => [auto, ...audios];
  @override
  String? selectedSubtitleId;
  @override
  String? selectedAudioId;
  double? firstPlaySpeed;
  String? firstPlaySubtitle, firstPlayAudio;
  @override
  Future<void> subtitle(TrackOption track) async =>
      selectedSubtitleId = track.id;
  @override
  Future<void> audio(TrackOption track) async => selectedAudioId = track.id;
  @override
  Future<void> play() async {
    firstPlaySpeed ??= speed;
    firstPlaySubtitle ??= selectedSubtitleId;
    firstPlayAudio ??= selectedAudioId;
    await super.play();
  }
}

void main() {
  late AppStore store;
  late EmbyClient api;
  final sessions = <PlaybackSession>[];
  Json episode(String id) => {
    'Id': id,
    'Name': id,
    'Type': id == 'movie' ? 'Movie' : 'Episode',
    'SeriesId': id == 'other' ? 'other-series' : 'series',
    'RunTimeTicks': ticks(const Duration(minutes: 90)),
  };
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('PlaybackInfo')) {
          return response(jsonEncode(playbackData()), 200);
        }
        if (request.url.path.contains('Sessions/Playing')) {
          return response('', 204);
        }
        return response(
          jsonEncode(episode(request.url.path.split('/').last)),
          200,
        );
      }),
    )..session = syntheticSession();
  });
  tearDown(() async {
    for (final session in sessions) {
      await session.close();
      session.dispose();
    }
    sessions.clear();
    api.close();
    await store.log.flush();
    store.log.dispose();
    store.dispose();
  });
  Future<PlaybackSession> open(
    String id, {
    EpisodeContinuity? carry,
    bool missing = false,
  }) async {
    final next = id != 'one';
    final backend = ContinuousBackend(
      [
        sub(next ? '9' : '1', 'chs'),
        if (!missing) sub(next ? '1' : '2', 'eng'),
      ],
      [
        audio(next ? '2' : '1', 'jpn'),
        if (!missing) audio(next ? '1' : '2', 'eng'),
      ],
    );
    final session = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem(episode(id)),
      backend: backend,
    );
    sessions.add(session);
    await session.open(continuity: carry);
    await session.trackSelection?.refresh();
    return session;
  }

  test(
    'same series inherits base speed and manual descriptors before playback; fresh open is 1x',
    () async {
      final first = await open('one');
      await first.setSpeed(2);
      await first.chooseTrack(true, first.trackOptions(true).last);
      await first.chooseTrack(false, first.trackOptions(false).last);
      await first.beginSpeedHold(3);
      final carry = first.continuitySnapshot!;
      expect(
        carry.speed,
        2,
        reason: 'temporary hold is not the chosen base speed',
      );
      await first.endSpeedHold();
      // Previous visits to this next item must not override the current binge.
      await store.saveTrackChoice(
        first.account,
        [
          'item:${jsonEncode(['two', 'source-1'])}',
        ],
        true,
        TrackChoice.fromTrack(sub('9', 'chs')),
      );
      final next = await open('two', carry: carry);
      final b = next.backend as ContinuousBackend;
      expect(b.firstPlaySpeed, 2);
      expect(b.firstPlaySubtitle, '1');
      expect(b.firstPlayAudio, '1');
      expect(next.speed, 2);
      final previous = await open('one', carry: next.continuitySnapshot);
      expect(previous.speed, 2);
      expect(previous.selectedTrack(true), '2');
      expect(previous.selectedTrack(false), '2');
      expect((await open('two')).speed, 1);
    },
  );
  test(
    'manual subtitle off and return to auto remain explicit across changed IDs',
    () async {
      final first = await open('one');
      await first.chooseTrack(true, off);
      final second = await open('two', carry: first.continuitySnapshot);
      expect(second.selectedTrack(true), 'no');
      await second.chooseTrack(true, auto);
      final third = await open('one', carry: second.continuitySnapshot);
      expect(third.selectedTrack(true), '1');
      expect(third.trackSelection!.automatic(true), isTrue);
    },
  );
  test(
    'explicitly selecting the current hold rate updates the carried base without another rate write',
    () async {
      final first = await open('one');
      await first.setSpeed(2);
      await first.beginSpeedHold(3);
      await first.setSpeed(3, source: SpeedChangeSource.menu);
      expect(first.continuitySnapshot!.speed, 3);
      await first.endSpeedHold();
      expect(first.speed, 3);
      expect((await open('two', carry: first.continuitySnapshot)).speed, 3);
    },
  );
  test(
    'failure during temporary hold retains chosen base for in-page retry',
    () async {
      final first = await open('one');
      await first.setSpeed(2);
      await first.beginSpeedHold(3);
      (first.backend as ContinuousBackend).failures.add('合成播放失败');
      await Future<void>.delayed(Duration.zero);
      expect(first.ready, isFalse);
      expect(first.continuitySnapshot!.speed, 2);
      expect((await open('one', carry: first.continuitySnapshot)).speed, 2);
      expect((await open('one')).speed, 1);
    },
  );
  test(
    'missing manual language falls back without forgetting the intended choice',
    () async {
      final first = await open('one');
      await first.chooseTrack(true, first.trackOptions(true).last);
      final second = await open(
        'two',
        carry: first.continuitySnapshot,
        missing: true,
      );
      expect(second.selectedTrack(true), '9');
      final third = await open('three', carry: second.continuitySnapshot);
      expect(third.selectedTrack(true), '1');
    },
  );
  test(
    'continuity never crosses series, movie, missing identity, or accounts',
    () async {
      final first = await open('one');
      await first.setSpeed(2);
      final carry = first.continuitySnapshot!;
      expect((await open('other', carry: carry)).speed, 1);
      expect((await open('movie', carry: carry)).speed, 1);
      expect(
        carry.matches(
          first.account,
          MediaItem({'Id': 'unknown', 'Type': 'Episode'}),
        ),
        isFalse,
      );
      api.session = syntheticSession('http://127.0.0.1:12');
      expect((await open('two', carry: carry)).speed, 1);
    },
  );
}
