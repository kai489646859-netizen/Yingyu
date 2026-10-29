import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/picture_brightness.dart';

void main() {
  for (final value in [0.0, 5.0, 10.0, 15.0]) {
    test(
      'picture $value writes only file-local gamma with acknowledgement',
      () async {
        var gamma = '0';
        final writes = <String>[];
        final actual = await writePictureGamma(
          value: value,
          read: (_) async => gamma,
          write: (key, value) async {
            writes.add(key);
            gamma = value;
          },
          active: () => true,
        );
        expect(actual, value);
        expect(writes, ['file-local-options/gamma']);
      },
    );
  }
  for (final bad in [double.nan, double.infinity, -1.0, 16.0]) {
    test('invalid picture level $bad never writes a property', () async {
      var writes = 0;
      await expectLater(
        writePictureGamma(
          value: bad,
          read: (_) async => '0',
          write: (_, _) async {
            writes++;
          },
          active: () => true,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(writes, 0);
    });
  }
  test(
    'rejected picture change restores the prior value and surfaces failure',
    () async {
      var gamma = '5';
      var writes = 0;
      await expectLater(
        writePictureGamma(
          value: 15,
          read: (_) async => gamma,
          write: (_, value) async {
            gamma = ++writes == 1 ? '6' : value;
          },
          active: () => true,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(double.parse(gamma), 5);
      expect(writes, 2);
    },
  );
  test('retired picture owner cannot roll back into another file', () async {
    var active = true;
    var writes = 0;
    await expectLater(
      writePictureGamma(
        value: 5,
        read: (_) async => '0',
        write: (_, _) async {
          writes++;
          active = false;
        },
        active: () => active,
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(writes, 1);
  });
  test('unsupported gamma is unavailable without modifying playback', () async {
    var writes = 0;
    await expectLater(
      writePictureGamma(
        value: 5,
        read: (_) async => 'unavailable',
        write: (_, _) async {
          writes++;
        },
        active: () => true,
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(writes, 0);
  });
}
