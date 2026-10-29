import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/opening_output.dart';

void main() {
  testWidgets(
    'eleven optional properties share one second, preserving color facts and rejecting late results',
    (tester) async {
      final pending = <String, Completer<String>>{};
      Map<String, String>? result;
      unawaited(
        openingOutputProperties((key) {
          final future = pending[key] = Completer<String>();
          return future.future;
        }, active: () => true).then((v) => result = v),
      );
      expect(pending.length, 11);
      pending['video-params/gamma']!.complete('pq');
      pending['video-params/colormatrix']!.complete('bt.2020-ncl');
      pending['audio-codec-name']!.complete('https://secret.invalid/no-export');
      await tester.pump(const Duration(milliseconds: 999));
      expect(result, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(result!['video-params/gamma'], 'pq');
      expect(result!['video-params/colormatrix'], 'bt.2020-ncl');
      expect(result!['audio-codec-name'], '未提供');
      expect(result!.values.where((v) => v == '未提供').length, 9);
      for (final entry in pending.values) {
        if (!entry.isCompleted) entry.complete('late');
      }
      await tester.pump();
      expect(result!.values, isNot(contains('late')));
    },
  );
  testWidgets(
    'closing an opening discards pending properties and handles read failures',
    (tester) async {
      var active = true;
      final gate = Completer<String>();
      final job = openingOutputProperties(
        (_) => gate.future,
        active: () => active,
      );
      active = false;
      gate.completeError(StateError('synthetic failure'));
      expect(await job, isEmpty);
      expect(
        await openingOutputProperties(
          (_) => throw StateError('must not read'),
          active: () => false,
        ),
        isEmpty,
      );
    },
  );
}
