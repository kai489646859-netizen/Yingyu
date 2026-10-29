import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/menu.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession;
import 'track_menu_test.dart' show MenuBackend;
import 'video_retry_test.dart' show StreamVideoController;

class PositionBackend extends MenuBackend implements SubtitlePositionBackend {
  final values = <String, String>{
    'sub-pos': '100',
    'sid': 'no',
    'sub-delay': '0',
  };
  final writes = <String>[];
  @override
  Future<double> readSubtitlePosition({required bool Function() allowed}) =>
      readMpvSubtitlePosition(
        read: (key) async => values[key]!,
        active: allowed,
      );
  @override
  Future<double> setSubtitlePosition(
    double value, {
    required bool Function() allowed,
  }) => writeMpvSubtitlePosition(
    value: value,
    read: (key) async => values[key]!,
    write: (key, text) async {
      writes.add(key);
      values[key] = text;
    },
    active: allowed,
  );
}

class TextPlayer extends PlatformPlayer {
  TextPlayer() : super(configuration: const PlayerConfiguration(libass: false));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final value in [100.0, 95.0, 50.0, 0.0]) {
    test(
      'writes and confirms only sub-pos at $value without switching tracks',
      () async {
        final values = {'sub-pos': '100', 'sid': 'no', 'sub-delay': '0'};
        final written = <String>[];
        final result = await writeMpvSubtitlePosition(
          value: value,
          read: (key) async => values[key]!,
          write: (key, v) async {
            values[key] = v;
            written.add(key);
          },
          active: () => true,
        );
        expect(result, value);
        expect(double.parse(values['sub-pos']!), 100 - value);
        expect(written, ['sub-pos']);
        expect(values['sid'], 'no');
        expect(values['sub-delay'], '0');
      },
    );
  }
  for (final bad in [double.nan, double.infinity, -1.0, 101.0]) {
    test('invalid position $bad causes no property write', () async {
      var writes = 0;
      await expectLater(
        writeMpvSubtitlePosition(
          value: bad,
          read: (_) async => '100',
          write: (_, _) async {
            writes++;
          },
          active: () => true,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(writes, 0);
    });
  }
  test('rejected position restores and confirms original', () async {
    var current = '100';
    final writes = <String>[];
    await expectLater(
      writeMpvSubtitlePosition(
        value: 40,
        read: (_) async => current,
        write: (_, value) async {
          writes.add(value);
          current = writes.length == 1 ? '90' : value;
        },
        active: () => true,
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(current, '100.0');
    expect(writes.length, 2);
  });
  test('retired session cannot perform a late rollback', () async {
    var active = true;
    var writes = 0;
    await expectLater(
      writeMpvSubtitlePosition(
        value: 50,
        read: (_) async => '100',
        write: (_, _) async {
          writes++;
          active = false;
        },
        active: () => active,
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(writes, 1);
  });
  for (final size in [
    const Size(320, 740),
    const Size(915, 412),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'three-dot position pane adjusts resets and leaves disabled subtitles off at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        await store.log.setEnabled(false);
        var requests = 0;
        final api = EmbyClient(
          client: MockClient((_) async {
            requests++;
            throw StateError('no network allowed');
          }),
        )..session = syntheticSession();
        final backend = PositionBackend();
        final session =
            PlaybackSession(
                api: api,
                store: store,
                item: MediaItem({'Id': 'test', 'Name': 'test'}),
                backend: backend,
              )
              ..ready = true
              ..loading = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            home: PlayerMenu(
              session: session,
              fit: BoxFit.contain,
              onToggle: () {},
              onSeek: (_) {},
            ),
          ),
        );
        await tester.ensureVisible(find.text('字幕位置'));
        await tester.tap(find.text('字幕位置'));
        await tester.pumpAndSettle();
        expect(find.text('0% · 默认'), findsOneWidget);
        await tester.ensureVisible(find.text('上移 5%'));
        await tester.tap(find.text('上移 5%'));
        await tester.pumpAndSettle();
        expect(double.parse(backend.values['sub-pos']!), 95);
        await tester.ensureVisible(find.text('恢复默认位置'));
        await tester.tap(find.text('恢复默认位置'));
        await tester.pumpAndSettle();
        expect(double.parse(backend.values['sub-pos']!), 100);
        expect(backend.values['sid'], 'no');
        expect(backend.writes.toSet(), {'sub-pos'});
        expect(requests, 0);
        expect(find.byType(CupertinoSlider), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        session.ready = false;
        session.dispose();
        await tester.runAsync(backend.dispose);
        api.close();
        await store.log.flush();
        store.log.dispose();
        store.dispose();
      },
    );
  }
  testWidgets(
    'real pinned Flutter subtitle renderer moves without rebuilding or scaling video',
    (tester) async {
      tester.view.physicalSize = const Size(900, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final native = TextPlayer();
      native.state = native.state.copyWith(
        width: 1920,
        height: 1080,
        subtitle: ['synthetic subtitle', ''],
      );
      final controller = StreamVideoController(Player(platformPlayer: native));
      Widget view(Alignment alignment) => MaterialApp(
        home: Video(
          controller: controller,
          controls: NoVideoControls,
          wakelock: false,
          subtitleViewConfiguration: SubtitleViewConfiguration(
            alignment: alignment,
          ),
        ),
      );
      await tester.pumpWidget(view(Alignment.bottomCenter));
      final videoState = tester.state(find.byType(Video));
      final bottom = tester.getTopLeft(find.text('synthetic subtitle')).dy;
      await tester.pumpWidget(view(Alignment.center));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('synthetic subtitle')).dy,
        lessThan(bottom - 100),
      );
      expect(identical(tester.state(find.byType(Video)), videoState), true);
      await tester.pumpWidget(view(Alignment.bottomCenter));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('synthetic subtitle')).dy, bottom);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(native.dispose);
      controller.notifier.value?.dispose();
      controller.notifier.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
