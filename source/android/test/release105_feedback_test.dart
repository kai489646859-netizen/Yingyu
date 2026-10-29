import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/feedback.dart';
import 'package:yingyu/playback/tracks.dart';

void main() {
  testWidgets(
    'temporary menu cover pauses the five visible seconds without renewing them',
    (tester) async {
      var visible = true, completed = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SourceFormatNotice(
                text: 'Dolby Vision · 杜比视界 → SDR · 色彩适配',
                visible: visible,
                onDone: () => completed++,
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      rebuild(() => visible = false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      expect(completed, 0);
      rebuild(() => visible = true);
      await tester.pump();
      expect(find.byKey(const Key('source-notice')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2900));
      expect(completed, 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(completed, 1);
      rebuild(() => visible = false);
      await tester.pump();
      rebuild(() => visible = true);
      await tester.pump();
      expect(find.byKey(const Key('source-notice')), findsNothing);
      expect(completed, 1);
    },
  );
  testWidgets('opening notice waits for its first visible frame', (
    tester,
  ) async {
    var visible = false;
    var completed = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return SourceFormatNotice(
              text: 'HDR10 · 高动态范围',
              visible: visible,
              onDone: () => completed++,
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(completed, 0, reason: 'an unseen notice must not be consumed');
    rebuild(() => visible = true);
    await tester.pump();
    expect(find.byKey(const Key('source-notice')), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(completed, 1);
  });

  test('audio wording describes a verified surround layout', () {
    expect(
      compactAudioTrackLabel(
        language: 'eng',
        codec: 'truehd',
        channels: 8,
        channelLayout: '7.1',
      ),
      contains('7.1 声道'),
    );
    expect(
      compactAudioTrackLabel(
        language: 'zho',
        codec: 'aac',
        channels: 2,
        channelLayout: 'stereo',
      ),
      contains('立体声'),
    );
    expect(
      compactAudioTrackLabel(
        language: 'eng',
        codec: 'truehd',
        channels: 8,
        channelLayout: '7.1',
      ),
      isNot(contains('全景声')),
    );
  });
}
