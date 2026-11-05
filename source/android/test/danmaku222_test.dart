import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/danmaku_flights.dart';
import 'package:yingyu/playback/danmaku_icons.dart';
import 'package:yingyu/playback/danmaku_preferences.dart';
import 'package:yingyu/playback/danmaku_sources.dart';

void main() {
  test(
    'late rows never enter mid-screen and a segment merge preserves the lane',
    () {
      final flights = DanmakuFlights();
      const expired = DanmakuComment(6, '晚到', 1, 0xffffff);
      const first = DanmakuComment(10.1, '正常', 1, 0xffffff);
      const second = DanmakuComment(10.4, '新分段', 1, 0xffffff);
      void step(double time, List<DanmakuComment> feed) => flights.advance(
        comments: feed,
        time: time,
        viewport: 800,
        lanes: 8,
        appearance: defaultDanmakuAppearance,
        measure: (_) => 120,
      );
      step(10, []);
      step(10.2, [expired, first]);
      final visible = flights.active.single;
      expect(visible.comment, first);
      expect(visible.x(10.2, 800), 800);
      step(10.5, [expired, first, second]);
      expect(flights.active.first, same(visible));
      expect(visible.x(10.5, 800), lessThan(800));
      expect(flights.active.last.lane, isNot(visible.lane));
      step(10.5, [expired, first, second]);
      expect(flights.active, hasLength(2));
      step(30, [expired, first, second]);
      expect(flights.active, isEmpty);
    },
  );

  test('featured retains distinct text and suppresses alternating repeats', () {
    final flights = DanmakuFlights();
    const rows = [
      DanmakuComment(1.1, '重复', 5, 0xffffff),
      DanmakuComment(1.3, '重复', 5, 0xffffff),
      DanmakuComment(1.5, '另一条', 5, 0xffffff),
      DanmakuComment(1.7, '重复', 5, 0xffffff),
    ];
    for (final time in [1.0, 1.2, 1.4, 1.6, 1.8]) {
      flights.advance(
        comments: rows,
        time: time,
        viewport: 800,
        lanes: 8,
        appearance: defaultDanmakuAppearance.update(featured: true),
        measure: (_) => 100,
      );
    }
    expect(flights.active.map((item) => item.comment.time), [1.1, 1.5, 1.7]);
  });

  test('legacy settings migrate and all appearance choices persist', () async {
    SharedPreferences.setMockInitialValues({
      'danmaku.enabled': false,
      'danmaku.compatible': 'https://example.com',
    });
    final prefs = await SharedPreferences.getInstance();
    final old = DanmakuPreferences.read(prefs);
    expect(old.enabled, isFalse);
    expect(old.compatible, 'https://example.com');
    final newValue = old.copyWith(
      enabled: true,
      automatic: false,
      appearance: old.appearance.update(
        featured: true,
        scroll: false,
        top: false,
        bottom: false,
        background: true,
        opacity: .4,
        area: .7,
        travel: 6,
        fontSize: 31,
        adaptive: false,
        delay: -.5,
      ),
    );
    await newValue.save(prefs);
    final reloaded = DanmakuPreferences.read(prefs);
    expect(reloaded.enabled, isTrue);
    expect(reloaded.automatic, isFalse);
    expect(reloaded.compatible, old.compatible);
    expect(reloaded.appearance, newValue.appearance);
  });

  test(
    'local XML stays separate from the media source and rejects entity declarations',
    () async {
      Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));
      final track = await DanmakuSources.localXml(
        bytes('<i><d p="7,1,24,16777215">本地弹幕</d></i>'),
      );
      expect(track!.source, '本地 XML');
      expect((await track.segments.single.load()).single.time, 7);
      await expectLater(
        DanmakuSources.localXml(
          bytes(
            '<!DOCTYPE i [<!ENTITY x SYSTEM "file:///private">]><i>&x;</i>',
          ),
        ),
        throwsFormatException,
      );
    },
  );

  for (final size in [
    const Size(320, 480),
    const Size(800, 360),
    const Size(1280, 800),
  ]) {
    testWidgets('desktop vectors below seekbar at left on $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selected = false, settings = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => PlayerChrome(
                title: '合成播放',
                visible: true,
                ready: true,
                playing: true,
                position: const Duration(seconds: 20),
                duration: const Duration(minutes: 22),
                episode: true,
                onEpisodes: () {},
                onRate: () {},
                onAudio: () {},
                onSubtitles: () {},
                onBack: () {},
                onToggle: () {},
                onSeekBack: () {},
                onSeekForward: () {},
                onMenu: () {},
                onScrubStart: () {},
                onScrub: (_) {},
                onScrubEnd: (_) {},
                danmakuFeatured: selected,
                onDanmakuFeatured: () => setState(() => selected = !selected),
                onDanmakuSettings: () => settings = true,
              ),
            ),
          ),
        ),
      );
      final tools = find.byKey(const Key('player-danmaku-tools'));
      final seek = find.byType(Slider);
      expect(
        tester.getTopLeft(tools).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(seek).dy - 1),
      );
      expect(tester.getTopLeft(tools).dx, lessThan(35));
      expect(find.byType(DanmakuToolbarIcon), findsNWidgets(2));
      await tester.tap(find.byTooltip('精选弹幕：关'));
      await tester.pump();
      expect(find.byTooltip('精选弹幕：开'), findsOneWidget);
      await tester.tap(find.byTooltip('弹幕设置'));
      expect(settings, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
