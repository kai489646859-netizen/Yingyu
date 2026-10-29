import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/byte_cache.dart';
import 'package:yingyu/ui/settings.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'cache_settings_test.dart' show fonts;
import 'core_test.dart' show response, syntheticSession;
import 'phone_layout_test.dart' show setDisplay;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final size in [
    const Size(320, 720),
    const Size(412, 915),
    const Size(1280, 800),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('video cache controls and confirmations $size $brightness', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        setDisplay(tester, size);
        final previousShadows = debugDisableShadows;
        debugDisableShadows = false;
        addTearDown(() => debugDisableShadows = previousShadows);
        await fonts();
        final dir = Directory.systemTemp.createTempSync('yingyu-cache-ui-');
        final cache = PlaybackByteCache(directory: () async => dir);
        await tester.runAsync(() => cache.configure(0));
        final store = AppStore(
          await SharedPreferences.getInstance(),
          videoCache: cache,
        );
        final api = EmbyClient(
          client: MockClient((_) async => response('{"Items":[]}', 200)),
        )..session = syntheticSession();
        final repo = BrowseRepository(
          api,
          BrowseCache(store.prefs),
          BrowsePreferences(store.prefs),
        );
        final capture = GlobalKey();
        addTearDown(() async {
          repo.dispose();
          api.close();
          store.dispose();
          await dir.delete(recursive: true);
        });
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: appTheme(brightness),
              home: Scaffold(
                body: SettingsPage(store: store, browse: repo),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> preview(String suffix) async {
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/ui-previews/$appVersion-video-cache-${size.width.toInt()}-${brightness.name}-$suffix.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        await tester.scrollUntilVisible(
          find.text('视频缓存上限'),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('视频缓存上限'));
        await tester.pumpAndSettle();
        for (final value in [0, 2, 5, 10, 20, 50, -1]) {
          expect(
            find.byKey(ValueKey('playback-cache-limit-choice-$value')),
            findsOneWidget,
          );
        }
        await preview('choices');
        await tester.tap(
          find.byKey(const ValueKey('playback-cache-limit-choice-2')),
        );
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await tester.pumpAndSettle();
        expect(store.playbackCacheGB, 2);
        await tester.scrollUntilVisible(
          find.text('允许流量播放'),
          -400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('允许流量播放'));
        await tester.pumpAndSettle();
        expect(store.allowMobilePlayback, true);
        await tester.scrollUntilVisible(
          find.text('视频缓存上限'),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await preview('settings');
        await tester.ensureVisible(find.text('清理视频缓存').first);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => cache.write('synthetic-file', 0, [1, 2, 3]),
        );
        await tester.tap(find.text('清理视频缓存').first);
        await tester.pumpAndSettle();
        expect(find.text('清理视频缓存？'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(cache.usedBytes, 35);
        await tester.tap(find.text('清理视频缓存').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认清理'));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await tester.pumpAndSettle();
        expect(cache.usedBytes, 0);
        expect(store.playbackCacheGB, 2);
        expect(store.allowMobilePlayback, true);
        await tester.pumpWidget(const SizedBox());
        debugDisableShadows = previousShadows;
      });
    }
  }
}
