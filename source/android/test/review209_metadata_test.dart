import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';

void main() {
  for (final number in ['1e309', '-1e309']) {
    test('overflowed JSON count is unknown, $number', () {
      final page = ItemPage.fromJson(
        object(jsonDecode('{"Items":[],"TotalRecordCount":$number}')),
      );
      expect(page.total, 0);
      expect(page.countKnown, isFalse);
    });
    test('overflowed movie duration and progress do not throw, $number', () {
      final item = MediaItem(
        object(
          jsonDecode(
            '{"Id":"film","Name":"Film","Type":"Movie","RunTimeTicks":$number,'
            '"UserData":{"PlaybackPositionTicks":$number}}',
          ),
        ),
      );
      expect(item.duration, Duration.zero);
      expect(item.resume, Duration.zero);
      expect(item.subtitle, isEmpty);
    });
    test('overflowed rating does not display Infinity, $number', () {
      final item = MediaItem(object(jsonDecode('{"CommunityRating":$number}')));
      expect(item.rating, isEmpty);
    });
  }
  test('ordinary finite metadata retains its numeric meaning', () {
    expect(integer(42.9), 42);
    expect(integer(-42.9), -42);
    expect(integer('123'), 123);
    expect(fromTicks(12345670), const Duration(microseconds: 1234567));
    expect(MediaItem({'CommunityRating': 8.25}).rating, '8.3');
    expect(integer(double.nan), 0);
  });
}
