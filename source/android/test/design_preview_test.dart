import 'offline_settle.dart';
// Offline renders of the real widgets. Synthetic artwork never enters the APK.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// The fixed cache manager exposes package:file in its public FileInfo contract.
// ignore: depend_on_referenced_packages
import 'package:file/local.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:yingyu/version.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/core/server_connection.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/login.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;

const titles = [
  '远山来信',
  '漫长的夏日',
  '无声之海',
  '夜航',
  '风起之时',
  '岛屿之间',
  '月光旅人',
  '最后一班列车',
];

class ArtworkCache extends CacheManager with ImageCacheManager {
  ArtworkCache(this.files) : super(Config('offline-design-preview'));
  final List<File> files;
  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    // The real Poster now probes disk before it can request the network path.
    // Serve the same synthetic artwork here; never open a real repository or
    // schedule its cleanup timer inside a layout-only fixture.
    final match = RegExp(r'poster-(\d+)').firstMatch(key);
    if (match == null) return null;
    return FileInfo(
      const LocalFileSystem().file(
        files[int.parse(match[1]!) % files.length].path,
      ),
      FileSource.Cache,
      DateTime(2099),
      key,
    );
  }

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) async* {
    final id = int.parse(
      Uri.parse(
        url,
      ).pathSegments.where((p) => p.startsWith('poster-')).single.substring(7),
    );
    yield FileInfo(
      const LocalFileSystem().file(files[id % files.length].path),
      FileSource.Cache,
      DateTime(2099),
      url,
    );
  }
}

Future<List<File>> paintArt() async {
  final result = <File>[];
  final palette = [
    [const Color(0xFF172B39), const Color(0xFF618A94), const Color(0xFFE1CFAF)],
    [const Color(0xFF6D343D), const Color(0xFFD7846B), const Color(0xFFF4DBA3)],
    [const Color(0xFF102935), const Color(0xFF347178), const Color(0xFF9CC9BE)],
    [const Color(0xFF171D37), const Color(0xFF645785), const Color(0xFFD9B292)],
    [const Color(0xFF30483F), const Color(0xFF769276), const Color(0xFFF0DC9B)],
    [const Color(0xFF164049), const Color(0xFF529F9A), const Color(0xFFDDECC5)],
    [const Color(0xFF282641), const Color(0xFF686881), const Color(0xFFEAD9CF)],
    [const Color(0xFF3D302B), const Color(0xFF997D69), const Color(0xFFF2CAA7)],
  ];
  for (var i = 0; i < titles.length; i++) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const rect = Rect.fromLTWH(0, 0, 360, 516);
    final colors = palette[i];
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, 0),
          const Offset(220, 516),
          [colors[0], colors[1]],
        ),
    );
    canvas.drawCircle(
      Offset(220 - (i % 3) * 35, 137 + i % 2 * 35),
      58,
      Paint()..color = colors[2].withValues(alpha: .9),
    );
    for (var n = 0; n < 5; n++) {
      final y = 238.0 + n * 39;
      final path = Path()
        ..moveTo(-20, y + 55)
        ..quadraticBezierTo(80 + n * 31, y - 116 + (i % 3) * 24, 200, y + 16)
        ..quadraticBezierTo(300, y + 68, 390, y - 34)
        ..lineTo(390, 540)
        ..lineTo(-20, 540)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.lerp(
            colors[0],
            colors[1],
            (4 - n) / 8,
          )!.withValues(alpha: .95),
      );
    }
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      text: TextSpan(
        text: titles[i],
        style: TextStyle(
          fontFamily: 'Roboto',
          color: colors[2],
          fontSize: 31,
          fontWeight: FontWeight.w600,
          letterSpacing: 4,
        ),
      ),
    );
    painter.layout(maxWidth: 320);
    painter.paint(canvas, Offset((360 - painter.width) / 2, 414));
    final caption = TextPainter(
      textDirection: TextDirection.ltr,
      text: const TextSpan(
        text: 'Y I N G Y U   /   S T U D I O',
        style: TextStyle(
          fontFamily: 'Roboto',
          color: Colors.white54,
          fontSize: 10,
        ),
      ),
    );
    caption.layout();
    caption.paint(canvas, Offset((360 - caption.width) / 2, 472));
    final picture = recorder.endRecording();
    final image = await picture.toImage(360, 516);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/synthetic-art/poster-$i.png')
      ..parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
    result.add(file);
    painter.dispose();
    caption.dispose();
    image.dispose();
    picture.dispose();
  }
  return result;
}

void main() {
  testWidgets(
    'Cupertino design: real screens in tablet landscape, portrait and phone portrait',
    (tester) async {
      final cacheDirectory = Directory('build/synthetic-art/cache')
        ..createSync(recursive: true);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => cacheDirectory.absolute.path,
      );
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      await tester.runAsync(() async {
        await ui.FragmentProgram.fromAsset(
          'packages/liquid_glass_widgets/shaders/lightweight_glass.frag',
        );
        await LightweightLiquidGlass.preWarm();
      });
      for (final font in {
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        'packages/cupertino_icons/CupertinoIcons':
            'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      }.entries) {
        await (FontLoader(
          font.key,
        )..addFont(rootBundle.load(font.value))).load();
      }
      final fontPath = Platform.environment['YINGYU_TEST_FONT'];
      if (fontPath != null) {
        for (final name in [
          'Roboto',
          'Ahem',
          '.SF UI Text',
          '.SF UI Display',
          'CupertinoSystemText',
          'CupertinoSystemDisplay',
        ]) {
          await (FontLoader(name)..addFont(
                Future.value(
                  ByteData.sublistView(File(fontPath).readAsBytesSync()),
                ),
              ))
              .load();
        }
      }
      final files = await tester.runAsync(paintArt);
      final oldCache = posterCache;
      final oldArtwork = artworkCache;
      posterCache = ArtworkCache(files!);
      artworkCache = posterCache;
      addTearDown(() {
        posterCache = oldCache;
        artworkCache = oldArtwork;
      });
      final items = List.generate(
        48,
        (i) => {
          'Id': 'poster-$i',
          'Name': titles[i % titles.length],
          'Type': i == 1 ? 'Series' : 'Movie',
          if (i == 1) 'RecursiveItemCount': 36,
          'ProductionYear': 2026 - i % 4,
          'DateCreated': DateTime.utc(
            2020,
            1,
            1,
          ).add(Duration(days: i)).toIso8601String(),
          'PremiereDate': DateTime.utc(2010 + i % 5, 1, 1).toIso8601String(),
          'RunTimeTicks': 76800000000,
          'CommunityRating': 8.9 - (i % 4) / 10,
          'ImageTags': {'Primary': 'synthetic'},
          'BackdropImageTags': ['synthetic'],
          'Overview':
              '在群山与海之间，一封迟来的信，开启了一段寻找与重逢的旅程。熟悉的街道、遥远的灯火，那些被时光收藏的日常，终于有了新的回响。',
          'UserData': {'PlaybackPositionTicks': i == 0 ? 18000000000 : 0},
        },
      );
      for (final spec in {
        'phone-portrait': const Size(412, 915),
        'tablet-portrait': const Size(900, 1280),
        'tablet-landscape': const Size(1280, 800),
      }.entries) {
        tester.view.physicalSize = spec.value;
        tester.view.display.size = spec.value;
        addTearDown(tester.view.display.resetSize);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        // Explicit list choice preserves the baseline tablet presentation for comparison.
        SharedPreferences.setMockInitialValues({
          'yingyu.ui.libraryDisplay.v1': 'standard',
        });
        final store = AppStore(await SharedPreferences.getInstance());
        await store.setTheme(ThemeMode.dark);
        final api = EmbyClient(
          client: MockClient((req) async {
            if (req.url.path.endsWith('/Users/synthetic-user')) {
              return response('{"Id":"synthetic-user"}', 200);
            }
            if (req.url.path.endsWith('/Items/Latest')) {
              return response(jsonEncode(items.take(8).toList()), 200);
            }
            if (req.url.path.endsWith('/Items/Resume')) {
              return response(
                jsonEncode({
                  'Items': [items.first],
                  'TotalRecordCount': 1,
                }),
                200,
              );
            }
            if (req.url.path.endsWith('/Views')) {
              return response(
                jsonEncode({
                  'Items': [
                    {'Id': 'movies', 'Name': '电影'},
                    {'Id': 'series', 'Name': '电视剧'},
                    {'Id': 'animation', 'Name': '动画'},
                  ],
                }),
                200,
              );
            }
            if (req.url.path.endsWith('/Seasons')) {
              return response(
                '{"Items":[{"Id":"season-1","Name":"第一季"}]}',
                200,
              );
            }
            if (req.url.path.endsWith('/Episodes')) {
              return response(
                jsonEncode({
                  'Items': List.generate(
                    8,
                    (i) => {
                      'Id': 'episode-$i',
                      'Type': 'Episode',
                      'Name': '第 ${i + 1} 集 · 夏日来信',
                      'ParentIndexNumber': 1,
                      'IndexNumber': i + 1,
                      'SeriesName': titles[1],
                    },
                  ),
                  'TotalRecordCount': 8,
                }),
                200,
              );
            }
            if (req.url.path.endsWith('/Items')) {
              return response(
                jsonEncode({'Items': items, 'TotalRecordCount': 48}),
                200,
              );
            }
            return response(
              jsonEncode(
                items.firstWhere(
                  (i) => req.url.path.endsWith('/${i['Id']}'),
                  orElse: () => items.first,
                ),
              ),
              200,
            );
          }),
        )..session = syntheticSession();
        await store.saveSession(api.session!);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: YingyuApp(
              store: store,
              api: api,
              backendFactory: () =>
                  throw StateError('No native playback in design previews'),
            ),
          ),
        );
        Future<void> settle() async {
          await settleOffline(tester);
          // File image decoding completes outside the fake widget-test clock.
          // Pump several real turns so the first screen is not captured mid-load.
          for (var turn = 0; turn < 8; turn++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 60)),
            );
            await settleOffline(tester);
          }
        }

        Future<void> capture(String page) async {
          expect(tester.takeException(), isNull, reason: '${spec.key} $page');
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject() as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/$appVersion-${spec.key}-$page.png',
            )..parent.createSync(recursive: true);
            file.writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        Future<void> revealSetting(String label) => tester.scrollUntilVisible(
          find.text(label),
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const PageStorageKey('settings-page')),
                matching: find.byType(Scrollable),
              )
              .first,
        );

        await settle();
        await capture('home-dark');
        expect(
          tester.widget<GlassNavigation>(find.byType(GlassNavigation)).onSearch,
          spec.key == 'phone-portrait' ? isNull : isNotNull,
          reason: 'Only the phone bottom search is removed',
        );
        await tester.tap(find.byKey(const Key('resume-view-all')));
        await settle();
        await capture('resume-all-dark');
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await settle();
        await tester.tap(find.text('媒体库').hitTestable().last);
        await settle();
        await capture('library-dark');
        final libraryScroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView).last)
            .controller!;
        libraryScroll.jumpTo(1300);
        await settle();
        expect(find.byKey(const Key('scroll-to-top')), findsOneWidget);
        api.connection.finish(
          api.connection.begin(),
          ServerStatus.disconnected,
          reason: '网络连接中断或服务器无法到达',
        );
        await tester.pump();
        await capture('library-disconnected-backtop');
        api.connection.finish(api.connection.begin(), ServerStatus.connected);
        await tester.tap(find.byKey(const Key('scroll-to-top')));
        await settle();
        expect(libraryScroll.offset, 0);
        await tester.tap(find.byKey(const Key('library-sort')));
        await settle();
        await capture('browse-options-dark');
        await tester.tap(find.text('影片名称'));
        await settle();
        await capture('alphabet-dark');
        if (spec.key == 'tablet-landscape') {
          for (final accent in AppAccent.available) {
            await store.setAccent(accent);
            for (final theme in [ThemeMode.dark, ThemeMode.light]) {
              await store.setTheme(theme);
              await settle();
              await capture('alphabet-${accent.name}-${theme.name}');
            }
          }
          await store.setAccent(AppAccent.blush);
          await store.setTheme(ThemeMode.dark);
          await settle();
        }
        await tester.tap(find.byKey(const Key('library-sort')));
        await settle();
        await tester.tap(find.text('添加时间'));
        await settle();
        await tester.tap(find.text(titles.first).first);
        await settle();
        await capture('detail-dark');
        await tester.tap(find.byTooltip('关闭'));
        await settle();
        await tester.tap(find.text(titles[1]).first);
        await settle();
        await capture('series-dark');
        if (spec.value.width < spec.value.height) {
          await tester.tap(find.text('剧集'));
          await settle();
          await capture('episodes-dark');
        }
        await tester.tap(find.byTooltip('关闭'));
        await settle();
        await tester.tap(find.text('账户').hitTestable().last);
        await settle();
        await capture('account-dark');
        await tester.tap(find.text('设置').hitTestable().last);
        await settle();
        await capture('settings-dark');
        await tester.tap(find.byKey(const Key('accent-setting-arrow')));
        await settle();
        await capture('theme-colors');
        await tester.tap(find.text('流金粉').hitTestable().last);
        await settle();
        await capture('settings-blush');
        expect(
          Theme.of(tester.element(find.text('主题色'))).colorScheme.primary,
          AppAccent.blush.dark,
        );
        await revealSetting('图片缓存上限');
        await settle();
        await capture('settings-cache');
        await tester.tap(find.byKey(const Key('cache-limit-arrow')));
        await settle();
        await capture('cache-limit');
        await tester.binding.handlePopRoute();
        await settle();
        await revealSetting('图片加载速度');
        await settle();
        await tester.tap(find.byKey(const Key('image-speed-arrow')));
        await settle();
        await capture('image-speed');
        await tester.binding.handlePopRoute();
        await settle();
        await revealSetting('图片请求上限');
        await settle();
        await tester.tap(find.byKey(const Key('image-limit-arrow')));
        await settle();
        await capture('image-limit');
        await tester.binding.handlePopRoute();
        await settle();
        await revealSetting('清理浏览资料缓存');
        await settle();
        await tester.tap(find.byKey(const Key('clear-browse-cache-arrow')));
        await settle();
        await settle();
        await capture('clear-confirm');
        await tester.tap(find.text('取消'));
        await settle();
        await tester.scrollUntilVisible(
          find.text('日志记录'),
          300,
          scrollable: find
              .descendant(
                of: find.byKey(const PageStorageKey('settings-page')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await settle();
        await tester.tap(find.byKey(const Key('logs-setting-arrow')));
        await settle();
        await settle();
        await capture('logs-dark');
        await tester.tap(find.byTooltip('关闭'));
        await settle();
        await tester.tap(find.text('设置').hitTestable().last);
        await settleOffline(tester);
        tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byKey(const PageStorageKey('settings-page')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position
            .jumpTo(0);
        await settle();
        await tester.ensureVisible(find.text('浅色'));
        await settle();
        await tester.tap(find.text('浅色'));
        await settle();
        await capture('settings-light');
        await tester.tap(find.text('账户').hitTestable().last);
        await settle();
        await capture('account-light');
        await tester.tap(find.text('媒体库').hitTestable().last);
        await settle();
        await capture('library-light');
        await tester.tap(find.text(titles.first).first);
        await settle();
        await capture('detail-light');
        await tester.tap(find.byTooltip('关闭'));
        await settle();
        await tester.tap(find.text(titles[1]).first);
        await settle();
        await capture('series-light');
        await tester.tap(find.byTooltip('关闭'));
        await settle();
        await tester.tap(find.text('首页').hitTestable().last);
        await settle();
        await capture('home-light');
        await tester.pumpWidget(const SizedBox());
        api.close();
        store.dispose();
        for (final brightness in [Brightness.dark, Brightness.light]) {
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: LoginPage(login: (_, _, _) async {}),
              ),
            ),
          );
          await settle();
          await capture('login-${brightness.name}');
        }
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
