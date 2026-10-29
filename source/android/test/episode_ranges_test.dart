import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response;
import 'poster_test.dart' show RecordingCache;
import 'offline_settle.dart' show syntheticImagePaths;

void main() {
  for (final spec in {
    'phone-portrait': const Size(412, 915),
    'tablet-portrait': const Size(900, 1280),
    'tablet-landscape': const Size(1280, 800),
  }.entries) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '1200 episodes keep natural neighbors and ranges, ${spec.key} ${brightness.name}',
        (tester) async {
          VisibilityDetectorController.instance.updateInterval = Duration.zero;
          syntheticImagePaths();
          final oldPoster = posterCache, oldArtwork = artworkCache;
          posterCache = RecordingCache();
          artworkCache = RecordingCache();
          addTearDown(() {
            posterCache = oldPoster;
            artworkCache = oldArtwork;
          });
          tester.view.physicalSize = spec.value;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          for (final font in {
            'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
            'packages/cupertino_icons/CupertinoIcons':
                'packages/cupertino_icons/assets/CupertinoIcons.ttf',
          }.entries) {
            await (FontLoader(
              font.key,
            )..addFont(rootBundle.load(font.value))).load();
          }
          final font = Platform.environment['YINGYU_TEST_FONT'];
          if (font != null) {
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
                      ByteData.sublistView(File(font).readAsBytesSync()),
                    ),
                  ))
                  .load();
            }
          }
          MediaItem episode(int n, String season) => MediaItem({
            'Id': '$season-ep$n',
            'Type': 'Episode',
            'Name': '第 $n 集 · 远行的故事',
            'SeriesId': 'series',
            'SeasonId': season,
            'IndexNumber': n,
            'ParentIndexNumber': int.parse(season.substring(1)),
          });
          var calls = 0;
          final api = EmbyClient(
            client: MockClient((request) async {
              final query = request.url.queryParameters;
              if (request.url.path.endsWith('/Seasons')) {
                return response(
                  jsonEncode({
                    'Items': List.generate(
                      5,
                      (i) => {
                        'Id': 's${i + 1}',
                        'Name': '第 ${i + 1} 季',
                        'IndexNumber': i + 1,
                      },
                    ),
                  }),
                  200,
                );
              }
              if (request.url.path.endsWith('/Episodes')) {
                calls++;
                expect(query['StartItemId'], null);
                expect(query['Limit'], null);
                final start = int.parse(query['StartIndex']!);
                return response(
                  jsonEncode({
                    'Items': List.generate(
                      1200,
                      (i) => episode(i + 1, query['SeasonId']!).data,
                    ).skip(start).take(400).toList(),
                    'TotalRecordCount': 1200,
                  }),
                  200,
                );
              }
              if (request.url.path.endsWith('/series')) {
                return response(
                  '{"Id":"series","Type":"Series","Name":"合成动漫 · 五季","Overview":"保留简介与剧集两个独立页签。"}',
                  200,
                );
              }
              fail('Unexpected metadata request ${request.url.path}');
            }),
          )..session = syntheticSession();
          final boundary = GlobalKey();
          String? played;
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: DetailPage(
                  item: MediaItem({'Id': 'series', 'Type': 'Series'}),
                  api: api,
                  watchedEpisode: (_) async => episode(100, 's2'),
                  play: (item, _, _) async => played = item.id,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (spec.value.width < spec.value.height) {
            expect(
              tester
                  .widget<CupertinoSlidingSegmentedControl<int>>(
                    find.byType(CupertinoSlidingSegmentedControl<int>),
                  )
                  .groupValue,
              0,
            );
            await tester.tap(find.text('剧集'));
            await tester.pumpAndSettle();
          }
          expect(
            calls,
            3,
            reason: 'A capped server is collected without a user paging step',
          );
          expect(find.text('从本季开头查看'), findsNothing);
          expect(find.text('加载更多剧集'), findsNothing);
          if (spec.value.width < spec.value.height) {
            expect(
              find.byType(CupertinoSlidingSegmentedControl<int>),
              findsOneWidget,
            );
          }
          final current = find.byKey(const ValueKey('detail-episode-s2-ep100'));
          expect(current.hitTestable(), findsOneWidget);
          expect(tester.widget<CupertinoButton>(current).color, isNotNull);
          expect(
            tester
                .widget<CupertinoButton>(
                  find.byKey(const ValueKey('episode-range-1')),
                )
                .color,
            isNotNull,
          );
          Future<void> capture(String name) async {
            await tester.pumpAndSettle();
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/ui-previews/$appVersion-${spec.key}-episode-$name-${brightness.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }

          await capture('focus');
          final list = find.byKey(const PageStorageKey('detail-episodes'));
          await tester.drag(list, const Offset(0, 140));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('detail-episode-s2-ep99')).hitTestable(),
            findsOneWidget,
          );
          await tester.drag(list, const Offset(0, -210));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('detail-episode-s2-ep101')).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const Key('episode-ranges-all')));
          await tester.pumpAndSettle();
          final panel = find.byKey(const Key('selection-menu-panel'));
          expect(tester.getSize(panel).width, lessThan(150));
          expect(tester.getSize(panel).height, lessThanOrEqualTo(420));
          await capture('picker');
          final picker = find
              .descendant(of: panel, matching: find.byType(Scrollable))
              .first;
          await tester.scrollUntilVisible(
            find.text('1001–1050'),
            250,
            scrollable: picker,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('1001–1050').last);
          await tester.pumpAndSettle();
          expect(
            find
                .byKey(const ValueKey('detail-episode-s2-ep1001'))
                .hitTestable(),
            findsOneWidget,
          );
          expect(
            calls,
            3,
            reason: 'Range navigation uses the complete season already loaded',
          );
          await tester.tap(find.text('第 1 季'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('detail-episode-s1-ep1')).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('detail-episode-s1-ep1')));
          await tester.pumpAndSettle();
          expect(played, 's1-ep1');
          expect(tester.takeException(), null);
          await tester.pumpWidget(const SizedBox());
          api.close();
        },
      );
    }
  }
}
