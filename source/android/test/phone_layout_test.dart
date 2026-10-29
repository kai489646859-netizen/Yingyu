import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/personal_library.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/library_layout.dart';
import 'package:yingyu/ui/login.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/settings_choice.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response;
import 'design_preview_test.dart' show paintArt, ArtworkCache, titles;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_settle.dart';

void setDisplay(
  WidgetTester tester,
  Size window, {
  Size? display,
  double dpr = 1,
}) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = window * dpr;
  tester.view.display.size = (display ?? window) * dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.display.resetSize);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'poster wall is first and default; saved tablet choice survives',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = InterfacePreferences(prefs);
      expect(settings.libraryDisplay, LibraryDisplay.posters);
      expect(LibraryDisplay.values.map((value) => value.label), [
        '海报墙',
        '图文列表',
      ]);
      for (final saved in LibraryDisplay.values) {
        await prefs.setString('yingyu.ui.libraryDisplay.v1', saved.name);
        expect(InterfacePreferences(prefs).libraryDisplay, saved);
      }
      settings.dispose();
    },
  );
  test(
    'full display classification handles density, rotation, 600 dp and invalid data',
    () {
      expect(phoneDisplay(const Size(1440, 3168), 4), isTrue);
      expect(phoneDisplay(const Size(3168, 1440), 4), isTrue);
      expect(phoneDisplay(const Size(1198, 2000), 2), isTrue);
      expect(phoneDisplay(const Size(1200, 2000), 2), isFalse);
      expect(phoneDisplay(const Size(2560, 1600), 2), isFalse);
      for (final size in [
        Size.zero,
        const Size(double.nan, 500),
        const Size(500, double.infinity),
      ]) {
        expect(phoneDisplay(size, 2), isFalse);
      }
      for (final dpr in [0.0, -1.0, double.nan, double.infinity]) {
        expect(phoneDisplay(const Size(1440, 3168), dpr), isFalse);
      }
    },
  );

  for (final display in [
    const Size(360, 792),
    const Size(600, 960),
    const Size(800, 1280),
  ]) {
    testWidgets(
      'display $display retains device class across split windows, rotation and keyboard',
      (tester) async {
        setDisplay(tester, const Size(360, 700), display: display, dpr: 2);
        final phone = display.shortestSide < 600;
        for (final size in [
          const Size(360, 700),
          const Size(700, 360),
          const Size(280, 650),
        ]) {
          tester.view.physicalSize = size * 2;
          for (final keyboard in [0.0, 280.0]) {
            await tester.pumpWidget(
              MaterialApp(
                home: Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
                    child: Builder(
                      builder: (context) {
                        expect(phoneLayout(context), phone);
                        expect(
                          shelfPosterWidth(context),
                          phone ? lessThanOrEqualTo(144) : 120,
                        );
                        expect(
                          pageHeadingSize(context),
                          phone ? 21 : (size.width > size.height ? 30 : 26),
                        );
                        return Scaffold(
                          body: ListView(
                            children: [
                              const SectionHeading('设置'),
                              GlassNavigation(index: 0, onChanged: (_) {}),
                              const SettingsGroup(
                                children: [
                                  SettingsRow('测试', subtitle: '仍保留原来的操作'),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
            expect(
              tester.getSize(find.byType(GlassNavigation)).height,
              phone ? 56 : 68,
            );
            expect(
              tester
                  .widget<ClipRRect>(find.byKey(const Key('phone-navigation')))
                  .borderRadius,
              BorderRadius.circular(phone ? 32 : 34),
            );
            expect(
              (tester
                          .widget<DecoratedBox>(
                            find.byKey(const Key('navigation-glass-indicator')),
                          )
                          .decoration
                      as BoxDecoration)
                  .borderRadius,
              BorderRadius.circular(phone ? 27 : 29),
            );
            expect(tester.takeException(), isNull);
          }
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final width in [320.0, 360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'phone $width ${brightness.name}: all browsing surfaces, menus and actual login fields',
        (tester) async {
          setDisplay(tester, Size(width, 880));
          syntheticImagePaths();
          VisibilityDetectorController.instance.updateInterval = Duration.zero;
          await fonts();
          final files = (await tester.runAsync(paintArt))!;
          final previousCache = posterCache, previousArtwork = artworkCache;
          posterCache = ArtworkCache(files);
          artworkCache = posterCache;
          addTearDown(() {
            posterCache = previousCache;
            artworkCache = previousArtwork;
          });
          // Old saved list choice must never enable a list on the phone.
          SharedPreferences.setMockInitialValues({
            'yingyu.ui.libraryDisplay.v1': 'standard',
          });
          final prefs = await SharedPreferences.getInstance();
          final store = AppStore(prefs);
          await store.setTheme(
            brightness == Brightness.light ? ThemeMode.light : ThemeMode.dark,
          );
          await store.log.setEnabled(false);
          final items = List.generate(
            30,
            (i) => <String, dynamic>{
              'Id': 'poster-$i',
              'Name': titles[i % titles.length],
              'Type': i == 1 ? 'Series' : 'Movie',
              if (i == 1) 'RecursiveItemCount': 123,
              'ProductionYear': 2026,
              'PremiereDate': '2026-01-01',
              'ImageTags': {'Primary': 'synthetic'},
              'RunTimeTicks': 76800000000,
              'CommunityRating': 8.2,
              'Overview': '合成离线简介。长文字应在手机中清晰展示，其他操作和服务器状态沿用。',
              'UserData': {'PlaybackPositionTicks': 18000000000},
            },
          );
          final api = EmbyClient(
            client: MockClient((req) async {
              final path = req.url.path;
              if (path.endsWith('/Users/synthetic-user')) {
                return response('{"Id":"synthetic-user"}', 200);
              }
              if (path.endsWith('/Views')) {
                return response(
                  '{"Items":[{"Id":"movies","Name":"影视","Type":"CollectionFolder"}]}',
                  200,
                );
              }
              if (path.endsWith('/Items/Latest')) {
                return response(jsonEncode(items.take(8).toList()), 200);
              }
              if (path.endsWith('/Items/Resume')) {
                return response(
                  jsonEncode({
                    'Items': items.take(4).toList(),
                    'TotalRecordCount': 4,
                  }),
                  200,
                );
              }
              if (path.endsWith('/Seasons')) {
                return response(
                  '{"Items":[{"Id":"season","Name":"第一季"}]}',
                  200,
                );
              }
              if (path.endsWith('/Episodes')) {
                return response(
                  jsonEncode({
                    'Items': List.generate(
                      60,
                      (i) => {
                        'Id': 'episode-$i',
                        'Name': '第 ${i + 1} 集 · 离线合成',
                        'Type': 'Episode',
                        'SeriesId': 'poster-1',
                        'SeriesName': titles[1],
                        'SeasonId': 'season',
                        'ParentIndexNumber': 1,
                        'IndexNumber': i + 1,
                      },
                    ),
                    'TotalRecordCount': 60,
                  }),
                  200,
                );
              }
              if (path.endsWith('/Items')) {
                return response(
                  jsonEncode({
                    'Items': items,
                    'TotalRecordCount': items.length,
                  }),
                  200,
                );
              }
              return response(
                jsonEncode(
                  items.firstWhere(
                    (i) => path.endsWith('/${i['Id']}'),
                    orElse: () => items.first,
                  ),
                ),
                200,
              );
            }),
          )..session = syntheticSession();
          await store.saveSession(api.session!);
          for (final item in items.take(6)) {
            await store.personal.setSaved(
              api.session!,
              SavedList.watchlist,
              MediaItem(item),
              true,
            );
          }
          final key = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: YingyuApp(
                store: store,
                api: api,
                backendFactory: () => throw StateError(
                  'No native playback in offline layout tests',
                ),
              ),
            ),
          );
          Future<void> settle() async {
            await settleOffline(tester);
            for (var i = 0; i < 4; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 35)),
              );
              await settleOffline(tester);
            }
            expect(tester.takeException(), isNull);
          }

          Future<void> capture(String page) async {
            await settle();
            await tester.runAsync(() async {
              final image =
                  await (key.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/ui-previews/$appVersion-mobile-${width.toInt()}-${brightness.name}-$page.png',
              )..parent.createSync(recursive: true);
              file.writeAsBytesSync(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }

          Future<void> back() async {
            tester.state<NavigatorState>(find.byType(Navigator).first).pop();
            await settle();
          }

          await capture('home');
          expect(
            tester
                .widget<GlassNavigation>(find.byType(GlassNavigation))
                .onSearch,
            isNull,
          );
          expect(find.bySemanticsLabel('搜索影片或演员'), findsNothing);
          final nav = tester.getRect(find.byType(GlassNavigation));
          expect(nav.height, 56);
          final firstPoster = tester.getRect(
            find.byKey(const ValueKey('resume-entrance-poster-0')),
          );
          final secondPoster = tester.getRect(
            find.byKey(const ValueKey('resume-entrance-poster-1')),
          );
          expect(firstPoster.left, 16);
          expect(secondPoster.left, lessThan(width));
          final resumeArt = tester.getRect(
            find.byKey(const ValueKey('resume-artwork-poster-0')),
          );
          expect(resumeArt.width / resumeArt.height, closeTo(16 / 9, .001));
          for (final action in [
            'home-search',
            'home-order',
            'home-refresh',
            'quick-account-switch',
          ]) {
            final rect = tester.getRect(find.byKey(ValueKey(action)));
            expect(rect.height, greaterThanOrEqualTo(44));
            expect(rect.width, greaterThanOrEqualTo(44));
          }
          await tester.tap(find.byKey(const Key('resume-view-all')));
          await capture('resume-all');
          expect(tester.getSize(find.byType(MediaCard).first).height, 112);
          await back();
          await tester.tap(find.byKey(const Key('home-search')));
          await capture('search');
          await tester.tap(find.byKey(const Key('search-back')));
          await settle();
          await tester.tap(find.byKey(const Key('navigation-tab-1')));
          await capture('library-posters');
          await tester.tap(find.byKey(const Key('library-picker')));
          await capture('library-picker');
          await tester.binding.handlePopRoute();
          await settle();
          await tester.tap(find.byType(LibraryPosterCard).first);
          await capture('detail');
          expect(
            tester.getSize(find.byKey(const Key('detail-poster'))).width,
            104,
          );
          await tester.tap(find.byTooltip('关闭'));
          await settle();
          await tester.tap(find.byKey(const Key('navigation-tab-0')));
          await settle();
          await tester.tapAt(
            tester
                    .getRect(find.byKey(const ValueKey('resume-poster-1')))
                    .topLeft +
                const Offset(8, 8),
          );
          await settle();
          await tester.tap(find.text('剧集'));
          await capture('episodes');
          await tester.tap(find.byTooltip('关闭'));
          await settle();
          await tester.tap(find.byKey(const Key('navigation-tab-2')));
          await capture('settings');
          expect(
            find.byKey(const Key('library-display-setting')),
            findsNothing,
          );
          expect(find.text('图文列表'), findsNothing);
          expect(prefs.getString('yingyu.ui.libraryDisplay.v1'), 'standard');
          await tester.tap(find.byKey(const Key('navigation-tab-1')));
          await capture('library-posters');
          final poster = tester.getRect(find.byType(LibraryPosterCard).first);
          final second = tester.getRect(find.byType(LibraryPosterCard).at(1));
          final third = tester.getRect(find.byType(LibraryPosterCard).at(2));
          expect(poster.top, second.top);
          expect(poster.top, third.top);
          expect(third.right, closeTo(width - 28, .01));
          expect(find.text('2026'), findsWidgets);
          expect(
            tester.getRect(find.byKey(const Key('main-browse-content'))).bottom,
            nav.top - 8,
          );
          await tester.tap(find.byKey(const Key('navigation-tab-3')));
          await capture('account');
          for (final removed in ['watchlist', 'likes', 'dislikes']) {
            expect(find.byKey(Key('personal-entry-$removed')), findsNothing);
          }
          await tester.tap(find.byKey(const Key('personal-entry-favorites')));
          await capture('personal-posters');
          await back();
          await tester.tap(find.byKey(const Key('account-avatar-switch')));
          await capture('accounts');
          await back();
          await tester.pumpWidget(const SizedBox());
          await settleOffline(tester);
          api.close();

          final submitted = <String>[];
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                theme: appTheme(brightness),
                home: LoginPage(
                  login: (a, u, p) async {
                    submitted.addAll([a, u, p]);
                  },
                ),
              ),
            ),
          );
          await capture('login');
          await tester.enterText(
            find.byKey(const Key('account-server')),
            'synthetic.invalid',
          );
          await tester.ensureVisible(find.byKey(const Key('account-username')));
          await tester.enterText(
            find.byKey(const Key('account-username')),
            '合成用户',
          );
          await tester.ensureVisible(find.byKey(const Key('account-password')));
          await tester.enterText(
            find.byKey(const Key('account-password')),
            'fake !%# password',
          );
          await tester.tap(find.byKey(const Key('login-password-visibility')));
          await tester.pump();
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('account-password')))
                .obscureText,
            isFalse,
          );
          await tester.ensureVisible(
            find.byKey(const Key('account-login-submit')),
          );
          await tester.tap(find.byKey(const Key('account-login-submit')));
          await settle();
          expect(submitted, [
            'http://synthetic.invalid:8096/emby',
            '合成用户',
            'fake !%# password',
          ]);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final scale in [1.3, 1.6, 2.0]) {
    testWidgets(
      'phone text scale $scale keeps rows, action targets and input usable',
      (tester) async {
        setDisplay(tester, const Size(320, 800));
        var opened = false;
        await fonts();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: ListView(
                    children: [
                      const SectionHeading('设置'),
                      SettingsGroup(
                        children: [
                          SettingsMenuRow(
                            title: '这是一个很长的设置标题',
                            subtitle: '长说明仍然换行，不通过锁定系统字号来缩小手机界面。',
                            icon: CupertinoIcons.settings,
                            onTap: () => opened = true,
                            trigger: const SizedBox(
                              width: 44,
                              height: 44,
                              child: Icon(CupertinoIcons.chevron_forward),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('这是一个很长的设置标题'));
        expect(opened, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
