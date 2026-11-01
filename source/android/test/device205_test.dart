import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/device_identity.dart';
import 'package:yingyu/playback/media_facts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(Device.channel, null));
  test('system model code is preserved without a guessed retail name', () {
    final value = DeviceIdentity.parse({
      'manufacturer': 'vivo',
      'brand': 'iQOO',
      'model': 'V-test-A',
      'androidRelease': '16',
      'sdk': 36,
      'serial': 'not-collected',
    });
    expect(value.model, 'V-test-A');
    expect(value.brand, 'iQOO');
    expect(value.system, 'Android 16 · API 36');
    expect(value.diagnostic, isNot(contains('iQOO 16')));
    expect(value.diagnostic, isNot(contains('not-collected')));
  });
  test(
    'missing malformed and sentinel fields never become known device facts',
    () {
      for (final raw in [
        null,
        'unknown',
        <String, Object>{},
        {
          'model': 'unknown',
          'brand': 5,
          'manufacturer': 'a\nforged',
          'androidRelease': 'null',
          'sdk': 36.5,
        },
      ]) {
        final value = DeviceIdentity.parse(raw);
        expect(value.model, isEmpty);
        expect(value.brand, isEmpty);
        expect(value.manufacturer, isEmpty);
        expect(value.system, isEmpty);
      }
    },
  );
  test(
    'one read-only local channel call returns only declared fields',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(Device.channel, (call) async {
        calls.add(call.method);
        expect(call.arguments, isNull);
        return {'model': 'Test phone', 'sdk': 35};
      });
      expect((await Device.identity()).model, 'Test phone');
      expect(calls, ['identity']);
    },
  );
  test(
    'unavailable native bridge does not fabricate or fail playback',
    () async {
      messenger.setMockMethodCallHandler(Device.channel, (_) async {
        throw PlatformException(code: 'unavailable');
      });
      expect((await Device.identity()).model, isEmpty);
    },
  );
  test('frame rate rejects invalid values and keeps reported precision', () {
    for (final value in [null, '', 'NaN', 'Infinity', '-1', '0']) {
      expect(mediaFrameRate(value), '未提供');
    }
    expect(mediaFrameRate('23.976024'), '23.976024 fps');
    expect(mediaFrameRate('60.000'), '60.000 fps');
  });
  test('invalid native numeric properties do not appear as measured facts', () {
    final facts = readPlaybackMediaFacts(
      read: (key) => switch (key) {
        'vid' || 'aid' => '1',
        'seeking' => 'no',
        'video-params/w' => '1920.5',
        'video-params/h' => '-1',
        'container-fps' => 'NaN',
        'audio-params/samplerate' => 'Infinity',
        'video-format' => 'unknown',
        _ => '',
      },
      active: () => true,
    );
    expect(facts.values.keys, unorderedEquals(['vid', 'aid']));
  });
}
