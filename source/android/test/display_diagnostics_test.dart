import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/display_diagnostics.dart';
import 'package:yingyu/playback/device.dart';

void main() {
  testWidgets('optional display reads share 600ms and cannot expose paths', (
    tester,
  ) async {
    final pending = <String, Completer<String>>{};
    Map<String, String>? result;
    unawaited(
      displayDiagnostics(
        (key) => (pending[key] = Completer<String>()).future,
        active: () => true,
      ).then((v) => result = v),
    );
    pending['video-params/sig-peak']!.complete('10.000000');
    pending['options/target-trc']!.complete('bt.1886');
    pending['video-target-params/gamma']!.complete('pq');
    pending['video-target-params/primaries']!.complete('bt.2020');
    pending['video-target-params/sig-peak']!.complete('49.261086');
    pending['options/tone-mapping']!.complete('https://secret.invalid/private');
    await tester.pump(const Duration(milliseconds: 599));
    expect(result, isNull);
    await tester.pump(const Duration(milliseconds: 1));
    expect(result!['video-params/sig-peak'], '10.000000');
    expect(result!['options/target-trc'], 'bt.1886');
    expect(result!['video-target-params/gamma'], 'pq');
    expect(result!['video-target-params/sig-peak'], '49.261086');
    expect(result!['options/tone-mapping'], '未提供');
    expect(result!.values.where((v) => v == '未提供').length, 18);
    for (final entry in pending.values) {
      if (!entry.isCompleted) entry.complete('late');
    }
    await tester.pump();
    expect(result!.values, isNot(contains('late')));
  });
  test('closing a session rejects late display results', () async {
    var active = true;
    final gate = Completer<String>();
    final job = displayDiagnostics((_) => gate.future, active: () => active);
    active = false;
    gate.complete('pq');
    expect(await job, isEmpty);
  });
  test(
    'brightness diagnostics retain system-following sentinel and reject unsafe values',
    () {
      final text = Device.brightnessDescription({
        'windowBrightness': -1,
        'systemBrightness': 127,
        'automaticBrightness': true,
      });
      expect(text, contains('窗口亮度=-1'));
      expect(text, contains('自动亮度=true'));
      expect(
        Device.brightnessDescription({
          'windowBrightness': double.nan,
          'systemBrightness': 'secret',
          'automaticBrightness': 'secret',
        }),
        isNot(contains('secret')),
      );
    },
  );
}
