import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/diagnostics.dart';

void main() {
  test(
    'actual premature terminal EOF remains an error and normal tail stays normal',
    () {
      expect(
        prematureMediaEnd(
          const Duration(milliseconds: 98267),
          const Duration(milliseconds: 1863850),
        ),
        isTrue,
      );
      expect(
        prematureMediaEnd(
          const Duration(seconds: 100),
          const Duration(seconds: 100),
        ),
        isFalse,
      );
      expect(
        prematureMediaEnd(
          const Duration(milliseconds: 98500),
          const Duration(seconds: 100),
        ),
        isFalse,
      );
      expect(prematureMediaEnd(Duration.zero, Duration.zero), isFalse);
    },
  );
}
