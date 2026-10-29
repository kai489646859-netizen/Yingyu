import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/menu.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'player_page_test.dart' show FakeDiscBackend;
import 'player_episode_menu_test.dart' show fonts;

class _Backend extends FakeDiscBackend {
  @override
  List<DiscTitle> get discTitles => [
    for (final (id, seconds) in [(1, 7200), (2, 60), (3, 30)])
      DiscTitle({
        'playlist': id,
        'main': id == 1,
        'duration': seconds * 90000,
        'clips': [
          {'id': '00001', 'in': 0, 'out': seconds * 90000},
        ],
        'chapters': [0],
      }),
  ];
}

void main() {
  for (final selectedShort in [false, true]) {
    testWidgets(
      'disc menu folds short lists, can restore and select them; selected short=$selectedShort',
      (tester) async {
        await fonts();
        tester.view.physicalSize = const Size(915, 412);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        await store.log.setEnabled(false);
        var requests = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            requests++;
            return request.url.path.endsWith('PlaybackInfo')
                ? response(jsonEncode(playbackData()), 200)
                : request.url.path.contains('Sessions/Playing')
                ? response('', 204)
                : response('{"Id":"movie","Type":"Movie"}', 200);
          }),
        )..session = syntheticSession();
        final backend = _Backend()..gate.complete();
        final session = PlaybackSession(
          api: api,
          store: store,
          item: MediaItem({'Id': 'movie'}),
          backend: backend,
        );
        if (selectedShort) backend.discPlaylist = 3;
        final capture = GlobalKey();
        Future<void> shot(String name) async {
          if (selectedShort) return;
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('build/ui-previews/0.8.7-disc-$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        PlayerMenuChoice? choice;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              debugShowCheckedModeBanner: false,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      choice = await Navigator.of(context)
                          .push<PlayerMenuChoice>(
                            MaterialPageRoute(
                              builder: (_) => PlayerMenu(
                                session: session,
                                initialPane: 'disc',
                                fit: BoxFit.contain,
                                onToggle: () {},
                                onSeek: (_) {},
                              ),
                            ),
                          );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final before = requests;
        final labels = backend.discTitles.map((t) => t.label).toList();
        expect(find.text(labels[0]), findsOneWidget);
        expect(find.text(labels[1]), findsNothing);
        final showAll = find.text('显示全部播放列表（另 ${selectedShort ? 1 : 2} 项）');
        await tester.scrollUntilVisible(showAll, 100);
        await tester.pumpAndSettle();
        expect(
          find.text(labels[2]),
          selectedShort ? findsOneWidget : findsNothing,
        );
        await shot('short-folded');
        await tester.tap(showAll);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text(labels[1]), 80);
        await tester.pumpAndSettle();
        expect(find.text(labels[1]), findsOneWidget);
        final collapse = find.text('收起短播放列表');
        await tester.scrollUntilVisible(collapse, 80);
        await tester.pumpAndSettle();
        expect(find.text(labels[2]), findsOneWidget);
        await shot('all-lists');
        await tester.tap(collapse);
        await tester.pumpAndSettle();
        expect(find.text(labels[1]), findsNothing);
        await tester.scrollUntilVisible(showAll, 80);
        await tester.pumpAndSettle();
        await tester.tap(showAll);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text(labels[1]), -80);
        await tester.pumpAndSettle();
        await tester.tap(find.text(labels[1]));
        await tester.pumpAndSettle();
        expect(choice?.pane, 'disc');
        expect(choice?.value, 2);
        expect(requests, before);
        expect(backend.discTitles.length, 3);
        expect(backend.selectedDiscPlaylist, selectedShort ? 3 : 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await session.close();
        api.close();
        await store.log.flush();
        store.log.dispose();
        store.dispose();
      },
    );
  }
}
