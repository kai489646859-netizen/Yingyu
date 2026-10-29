import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/track_selection.dart';
import 'package:yingyu/playback/tracks.dart';
import 'core_test.dart' show syntheticSession;

const first = TrackOption('2', 'track2', '2', codec: 'aac');
const last = TrackOption('3', 'track3', '3', codec: 'dts');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
  });
  for (final subtitles in [false, true]) {
    test(
      'latest queued choice wins for subtitles=$subtitles without saving stale result',
      () async {
        final entered = Completer<void>(),
            release = Completer<void>(),
            second = Completer<void>(),
            finish = Completer<void>();
        final calls = <String>[];
        final controller = TrackSelection(
          store: store,
          account: syntheticSession(),
          itemScope: 'item:test',
          options: (_) => [first, last],
          selected: (_) => '1',
          onChanged: () {},
          apply: (_, track) async {
            calls.add(track.id);
            if (track.id == '2') {
              entered.complete();
              await release.future;
            } else {
              second.complete();
              await finish.future;
            }
          },
        );
        final a = controller.choose(subtitles, first);
        await entered.future;
        final b = controller.choose(subtitles, last);
        release.complete();
        await a;
        await second.future;
        expect(
          store.trackChoice(syntheticSession(), 'item:test', subtitles),
          null,
        );
        finish.complete();
        await b;
        expect(
          store
              .trackChoice(syntheticSession(), 'item:test', subtitles)
              ?.data['id'],
          '3',
        );
        expect(calls, ['2', '3']);
      },
    );
  }
  test('queued old choice is skipped before native selection begins', () async {
    final calls = <String>[];
    final controller = TrackSelection(
      store: store,
      account: syntheticSession(),
      itemScope: 'item:test',
      options: (_) => [first, last],
      selected: (_) => '1',
      onChanged: () {},
      apply: (_, track) async {
        calls.add(track.id);
      },
    );
    await Future.wait([
      controller.choose(false, first),
      controller.choose(false, last),
    ]);
    expect(calls, ['3']);
  });
  test('audio and subtitle intents do not cancel each other', () async {
    final calls = <String>[];
    final controller = TrackSelection(
      store: store,
      account: syntheticSession(),
      itemScope: 'item:test',
      options: (_) => [first, last],
      selected: (_) => '1',
      onChanged: () {},
      apply: (sub, track) async {
        calls.add('$sub:${track.id}');
      },
    );
    await Future.wait([
      controller.choose(false, first),
      controller.choose(true, last),
    ]);
    expect(calls, ['false:2', 'true:3']);
    expect(
      store.trackChoice(syntheticSession(), 'item:test', false)?.data['id'],
      '2',
    );
    expect(
      store.trackChoice(syntheticSession(), 'item:test', true)?.data['id'],
      '3',
    );
  });
  test('failed switch is not saved and later choice still works', () async {
    final controller = TrackSelection(
      store: store,
      account: syntheticSession(),
      itemScope: 'item:test',
      options: (_) => [first, last],
      selected: (_) => '1',
      onChanged: () {},
      apply: (_, track) async {
        if (track.id == '2') throw const AppFailure('restored old track');
      },
    );
    await expectLater(
      controller.choose(false, first),
      throwsA(isA<AppFailure>()),
    );
    expect(store.trackChoice(syntheticSession(), 'item:test', false), null);
    await controller.choose(false, last);
    expect(
      store.trackChoice(syntheticSession(), 'item:test', false)?.data['id'],
      '3',
    );
  });
  test('close while applying does not persist late choice', () async {
    final entered = Completer<void>(), finish = Completer<void>();
    final controller = TrackSelection(
      store: store,
      account: syntheticSession(),
      itemScope: 'item:test',
      options: (_) => [first, last],
      selected: (_) => '1',
      onChanged: () {},
      apply: (_, _) async {
        entered.complete();
        await finish.future;
      },
    );
    final job = controller.choose(false, first);
    await entered.future;
    controller.close();
    finish.complete();
    await job;
    expect(store.trackChoice(syntheticSession(), 'item:test', false), null);
  });
}
