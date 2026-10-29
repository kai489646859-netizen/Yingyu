import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'host/playback107/placement.dart';
import 'track_menu_test.dart' show MenuBackend;

class ActualPlacementBackend118 extends MenuBackend
    implements SubtitlePositionBackend, DefaultSubtitlePositionBackend {
  final placement = PlacementHarness();
  @override
  bool get usesDefaultSubtitlePosition => placement.usesDefaultSubtitlePosition;
  @override
  Future<double> readSubtitlePosition({required bool Function() allowed}) =>
      placement.readSubtitlePosition(allowed: allowed);
  @override
  Future<double> setSubtitlePosition(
    double value, {
    required bool Function() allowed,
  }) => placement.setSubtitlePosition(value, allowed: allowed);
  @override
  Future<double> resetSubtitlePosition({required bool Function() allowed}) =>
      placement.resetSubtitlePosition(allowed: allowed);
}

void main() {
  for (final size in [const Size(1280, 837), const Size(915, 412)]) {
    testWidgets(
      'actual player route drags subtitle thumb from default at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          Device.channel,
          (call) async => call.method == 'focus'
              ? true
              : call.method == 'levels'
              ? {'brightness': .5, 'volume': .5}
              : null,
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(Device.channel, null),
        );
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        await store.log.setEnabled(false);
        final api = EmbyClient(
          client: MockClient(
            (request) async => request.url.path.endsWith('PlaybackInfo')
                ? response(jsonEncode(playbackData()), 200)
                : request.url.path.contains('Sessions/Playing')
                ? response('', 204)
                : response('{"Id":"movie","Type":"Movie"}', 200),
          ),
        )..session = syntheticSession();
        final backend = ActualPlacementBackend118()
          ..gate.complete()
          ..placement.textPosition(0)
          ..placement.io.values['yingyu-subtitle-layout'] = '-2';
        final session = PlaybackSession(
          api: api,
          store: store,
          item: MediaItem({'Id': 'movie'}),
          backend: backend,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            home: PlayerPage(createSession: () => session),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('播放器菜单'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('字幕位置'));
        await tester.tap(find.text('字幕位置'));
        await tester.pumpAndSettle();
        final slider = find.byKey(const Key('subtitle-position-slider'));
        expect(tester.widget<CupertinoSlider>(slider).onChanged, isNotNull);
        final rect = tester.getRect(slider);
        final gesture = await tester.startGesture(
          Offset(rect.left + 15, rect.center.dy),
        );
        await gesture.moveBy(const Offset(25, 0));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(Offset(rect.width * .6, 0));
        await tester.pump(const Duration(milliseconds: 50));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.widget<CupertinoSlider>(slider).value, greaterThan(40));
        expect(backend.placement.rememberedPosition, greaterThan(40));
        expect(backend.placement.io.values['sid'], 'no');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        for (var i = 0; i < 20 && !backend.disposed; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(backend.disposed, true);
        api.close();
        store.log.dispose();
        store.dispose();
      },
    );
  }
}
