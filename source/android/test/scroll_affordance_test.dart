import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/ui/logs.dart';
import 'package:yingyu/ui/scroll_behavior.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';

Future<void> fonts() async {
  for (final font in {
    'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    'packages/cupertino_icons/CupertinoIcons':
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
  }.entries) {
    await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
  }
  final path = Platform.environment['YINGYU_TEST_FONT'];
  if (path != null) {
    for (final name in [
      'Roboto',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
    ]) {
      await (FontLoader(name)..addFont(
            Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
          ))
          .load();
    }
  }
}

void main() {
  for (final size in [const Size(412, 892), const Size(1280, 800)]) {
    for (final brightness in Brightness.values) {
      testWidgets('log thumb and return-to-top $size $brightness', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await fonts();
        final log = DiagnosticLog();
        for (var i = 0; i < 100; i++) {
          log.add(LogArea.player, '合成加载记录 $i：资源加载完成；倍速=3.0；前向缓存已按设备容量调整。');
        }
        final repaint = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(brightness),
            scrollBehavior: const AppScrollBehavior(),
            home: RepaintBoundary(
              key: repaint,
              child: LogsPage(log: log),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        expect(scroll.position.maxScrollExtent, greaterThan(1000));
        expect(find.byKey(const Key('scroll-to-top')), findsNothing);
        final raw = tester
            .widgetList<RawScrollbar>(find.byType(RawScrollbar))
            .where(
              (w) => w.controller?.positions.contains(scroll.position) == true,
            )
            .single;
        expect(raw.thumbVisibility, isTrue);
        expect(raw.interactive, isTrue);
        scroll.jumpTo(1500);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('scroll-to-top')), findsOneWidget);
        final boundary =
            repaint.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final file = File(
          'build/ui-previews/$appVersion-logs-${size.width.toInt()}-${brightness.name}.png',
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.byKey(const Key('scroll-to-top')));
        await tester.pumpAndSettle();
        expect(scroll.offset, closeTo(0, .1));
        expect(find.byKey(const Key('scroll-to-top')), findsNothing);
        // Filtering/selection data remain available after returning.
        expect(log.entries, hasLength(100));
        await tester.pumpWidget(const SizedBox());
        log.dispose();
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('nested lists get independent thumbs on Android', (tester) async {
    final outer = ScrollController(), inner = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        scrollBehavior: const AppScrollBehavior(),
        home: Scaffold(
          body: ListView(
            controller: outer,
            children: [
              SizedBox(
                height: 200,
                child: ListView(
                  controller: inner,
                  primary: false,
                  children: List.generate(
                    20,
                    (i) => SizedBox(height: 50, child: Text('inner $i')),
                  ),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<RawScrollbar>(find.byType(RawScrollbar))
          .map((w) => w.controller!.position),
      containsAll([outer.position, inner.position]),
    );
    inner.jumpTo(100);
    await tester.pumpAndSettle();
    expect(outer.offset, 0);
    expect(inner.offset, 100);
    await tester.pumpWidget(const SizedBox());
    outer.dispose();
    inner.dispose();
    expect(tester.takeException(), isNull);
  });
  testWidgets('horizontal lists still scroll with no horizontal thumb', (
    tester,
  ) async {
    final horizontal = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        home: Scaffold(
          body: ListView(
            controller: horizontal,
            scrollDirection: Axis.horizontal,
            children: const [
              SizedBox(width: 3000, child: Text('horizontal content')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RawScrollbar), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(horizontal.offset, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    horizontal.dispose();
  });
  testWidgets(
    'retained pages may share a primary controller without sharing thumbs',
    (tester) async {
      final shared = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          home: Scaffold(
            body: PrimaryScrollController(
              controller: shared,
              child: IndexedStack(
                index: 0,
                children: [
                  for (var i = 0; i < 2; i++)
                    ListView(
                      primary: true,
                      children: const [SizedBox(height: 2400)],
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(shared.positions.length, 2);
      final bars = tester
          .widgetList<RawScrollbar>(
            find.byType(RawScrollbar, skipOffstage: false),
          )
          .toList();
      expect(bars, hasLength(2));
      expect(
        bars.every((bar) => bar.controller!.positions.length == 1),
        isTrue,
      );
      bars.first.controller!.jumpTo(200);
      await tester.pumpAndSettle();
      expect(bars.last.controller!.offset, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      shared.dispose();
    },
  );
}
