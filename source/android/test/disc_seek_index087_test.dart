import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_seek_index.dart';

void main() {
  Map<String, Object> row() => {
    'clip': '00001',
    'pid': 4113,
    'packetCount': 1000,
    'points': [
      [0, 0],
      [90000, 100],
      [180000, 200],
    ],
  };
  String encode(Object value) =>
      discSeekIndex('session', jsonEncode(value), {'00001'});
  test('encodes only validated current-session CLPI access points', () {
    expect(
      encode([row()]),
      'YI1|session|00001,4113,1000,0:0,90000:100,180000:200',
    );
  });
  test('rejects wrong clip, duplicate clip and noninteger metadata', () {
    expect(
      encode([
        {...row(), 'clip': '00002'},
      ]),
      isEmpty,
    );
    expect(encode([row(), row()]), isEmpty);
    expect(
      encode([
        {...row(), 'pid': 4113.0},
      ]),
      isEmpty,
    );
    expect(
      encode([
        {...row(), 'packetCount': -1},
      ]),
      isEmpty,
    );
  });
  test('rejects regressions, rollover, out-of-file and malformed points', () {
    for (final points in [
      [
        [90000, 0],
        [0, 100],
      ],
      [
        [0, 100],
        [90000, 0],
      ],
      [
        [0, 0],
        [90000, 1000],
      ],
      [
        [0, 0],
        [0x200000000, 100],
      ],
      [
        [0, 0],
      ],
      [
        [0, 0],
        [90000],
      ],
    ]) {
      expect(
        encode([
          {...row(), 'points': points},
        ]),
        isEmpty,
      );
    }
    expect(discSeekIndex('session|other', '[]', {}), isEmpty);
    expect(discSeekIndex('session', 'not json', {}), isEmpty);
  });
  test(
    'restores disc index before ordinary media and before another disc',
    () async {
      final setup = DiscSeekIndexSetup();
      var value = '';
      Future<String> read(String _) async => value;
      Future<void> write(String _, String next) async {
        value = next;
      }

      expect(
        await setup.prepare(index: 'first', read: read, write: write),
        isTrue,
      );
      expect(
        await setup.prepare(index: 'second', read: read, write: write),
        isTrue,
      );
      expect(value, 'second');
      expect(await setup.prepare(index: '', read: read, write: write), isFalse);
      expect(value, isEmpty);
    },
  );
  test(
    'failed optional write restores original and preserves explicit settings',
    () async {
      final setup = DiscSeekIndexSetup();
      var value = '';
      Future<String> read(String _) async => value;
      Future<void> write(String _, String next) async {
        value = next == 'index' ? 'bad' : next;
      }

      expect(
        await setup.prepare(index: 'index', read: read, write: write),
        isFalse,
      );
      expect(value, isEmpty);
      value = 'explicit';
      expect(
        await setup.prepare(index: 'index', read: read, write: write),
        isFalse,
      );
      expect(value, 'explicit');
    },
  );
  test(
    'failed restoration remains an error rather than leaking a stale index',
    () async {
      final setup = DiscSeekIndexSetup();
      var value = '';
      Future<String> read(String _) async => value;
      Future<void> write(String _, String next) async {
        value = next;
      }

      await setup.prepare(index: 'index', read: read, write: write);
      await expectLater(
        setup.prepare(index: '', read: read, write: (_, _) async {}),
        throwsStateError,
      );
      await setup.prepare(index: '', read: read, write: write);
      expect(value, isEmpty);
    },
  );
}
