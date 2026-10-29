import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/subtitle_position_memory.dart';
import 'package:yingyu/playback/tracks.dart';
import 'host/notice103/subtitle_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'phone fit never replaces an explicitly remembered disc manual position',
    () async {
      final h = SubtitleScopeHarness()
        ..configureDiscSubtitlePosition(35)
        ..useDisc()
        ..phone();
      await h.initialize();
      await h.setPhoneFill(true);
      await h.setPhoneFill(false);
      expect(h.automatic, false);
      expect(h.io.values['yingyu-subtitle-screen-position'], 'yes');
      expect(double.parse(h.io.values['sub-pos']!), 65);
    },
  );
  for (final phone in [true, false]) {
    test(
      'fit changes preserve authored disc layout and subtitle visibility on ${phone ? 'phone' : 'tablet'}',
      () async {
        final h = SubtitleScopeHarness()..useDisc();
        if (phone) {
          h.phone();
        } else {
          h.tablet();
        }
        await h.initialize();
        for (final fill in [true, false]) {
          await h.setPhoneFill(fill);
          expect(h.filled, fill);
          expect(h.io.values['yingyu-subtitle-screen-position'], 'no');
          expect(h.io.values['stretch-image-subs-to-screen'], 'no');
          expect(h.io.values['sid'], '1');
          expect(h.io.values['sub-visibility'], 'yes');
        }
      },
    );
  }
  TrackOption track({bool external = false, Object? value}) =>
      TrackOption('1', 'Synthetic', value ?? Object(), external: external);
  test(
    'disc automatic starts with authored flags, ignoring the legacy external manual position',
    () async {
      final h = SubtitleScopeHarness()
        ..configureSubtitlePosition(65)
        ..useDisc();
      await h.initialize();
      expect(h.discEmbedded, true);
      expect(h.automatic, true);
      expect(h.position, isNull);
      expect(h.io.values['yingyu-subtitle-screen-position'], 'no');
      expect(h.io.values['yingyu-subtitle-below-picture'], 'no');
      expect(h.io.values['stretch-image-subs-to-screen'], 'no');
      expect(double.parse(h.io.values['sub-pos']!), 100);
      expect(h.io.values['sid'], '1');
      expect(h.io.values['sub-visibility'], 'yes');
      expect(h.io.values['target-trc'], 'pq');
      final file = File('build/notice103/disc-default-policy.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'mode': 'disc-automatic',
          'properties': h.io.values,
          'scope':
              'Complete actual backend configure/select/init methods; synthetic native properties only.',
        }),
      );
    },
  );
  test(
    'disc manual memory still restores and ordinary memory stays separate',
    () async {
      final h = SubtitleScopeHarness()
        ..configureSubtitlePosition(65)
        ..configureDiscSubtitlePosition(25)
        ..useDisc();
      await h.initialize();
      expect(h.automatic, false);
      expect(h.position, 25);
      expect(double.parse(h.io.values['sub-pos']!), 75);
      expect(h.io.values['yingyu-subtitle-screen-position'], 'yes');
      expect(h.io.values['yingyu-subtitle-below-picture'], 'no');
      await h.selectTrack(track(external: true), '10');
      expect(h.discEmbedded, false);
      expect(h.position, 65);
      expect(double.parse(h.io.values['sub-pos']!), 35);
      await h.selectTrack(track(), '1');
      expect(h.discEmbedded, true);
      expect(h.position, 25);
      expect(double.parse(h.io.values['sub-pos']!), 75);
    },
  );
  test(
    'external subtitle on an ISO retains below-picture automatic layout, then internal restores authored',
    () async {
      final h = SubtitleScopeHarness()..useDisc();
      await h.initialize();
      await h.selectTrack(track(external: true), '10');
      expect(h.discEmbedded, false);
      expect(h.io.values['yingyu-subtitle-screen-position'], 'yes');
      expect(h.io.values['yingyu-subtitle-below-picture'], 'yes');
      await h.selectTrack(track(), '1');
      expect(h.discEmbedded, true);
      expect(h.io.values['yingyu-subtitle-screen-position'], 'no');
      expect(h.io.values['yingyu-subtitle-below-picture'], 'no');
    },
  );
  for (final source in ['alias', 'metadata', 'local']) {
    test(
      'external $source identity cannot inherit authored disc layout',
      () async {
        final h = SubtitleScopeHarness()..useDisc();
        await h.initialize();
        if (source == 'alias') h.external('10');
        if (source == 'metadata') h.metadataExternal('10');
        await h.selectTrack(
          track(
            value: source == 'local'
                ? const LocalSubtitle('C:/synthetic/sub.srt')
                : null,
          ),
          '10',
        );
        expect(h.discEmbedded, false);
        expect(h.io.values['yingyu-subtitle-below-picture'], 'yes');
      },
    );
  }
  test(
    'closing subtitles preserves the current scope and never enables them',
    () async {
      final h = SubtitleScopeHarness()..useDisc();
      await h.initialize();
      h.io.values['sid'] = 'no';
      h.io.values['sub-visibility'] = 'no';
      h.io.writes.clear();
      await h.selectTrack(track(), 'no');
      expect(h.discEmbedded, true);
      expect(h.io.writes, isEmpty);
      expect(h.io.values['sub-visibility'], 'no');
    },
  );
  test(
    'retired track layout cannot publish a new scope or restore properties into a new load',
    () async {
      final h = SubtitleScopeHarness()..useDisc();
      await h.initialize();
      h.io.writes.clear();
      h.io.afterWrite = h.retire;
      await expectLater(
        h.selectTrack(track(external: true), '10'),
        throwsException,
      );
      expect(h.discEmbedded, true);
      expect(h.io.writes.length, 1);
    },
  );
  test(
    'a rejected layout property rolls back while preserving the previous scope',
    () async {
      final h = SubtitleScopeHarness()..useDisc();
      await h.initialize();
      final before = Map<String, String>.of(h.io.values);
      h.io.reject = 'yingyu-subtitle-screen-position';
      await expectLater(
        h.selectTrack(track(external: true), '10'),
        throwsException,
      );
      expect(h.discEmbedded, true);
      expect(h.io.values, before);
    },
  );
  test(
    'phone and tablet each keep disc and regular preferences independent through reset',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final memory = SubtitlePositionMemory(prefs);
      for (final viewport in SubtitleViewport.values) {
        final regular = memory.claim(viewport);
        final disc = memory.claim(
          viewport,
          scope: SubtitlePositionScope.discEmbedded,
        );
        await memory.save(viewport, regular, 60, active: () => true);
        expect(
          memory.read(viewport, scope: SubtitlePositionScope.discEmbedded),
          isNull,
        );
        await memory.save(
          viewport,
          disc,
          30,
          active: () => true,
          scope: SubtitlePositionScope.discEmbedded,
        );
        await memory.save(
          viewport,
          disc,
          null,
          active: () => true,
          scope: SubtitlePositionScope.discEmbedded,
        );
        expect(memory.read(viewport), 60);
        expect(
          memory.read(viewport, scope: SubtitlePositionScope.discEmbedded),
          isNull,
        );
      }
    },
  );
}
