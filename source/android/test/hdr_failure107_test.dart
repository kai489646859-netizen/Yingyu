import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'host/hdr107_current_opening.dart' as current;
import 'host/hdr107_old_opening.dart' as old;

void main() {
  test(
    'failed HDR restoration cannot return successful opening admission',
    () async {
      final route = PlaybackRoute(
        url: 'https://example.invalid/synthetic.mkv',
        sourceId: 'source',
        sessionId: 'session',
        headers: {},
        streams: [],
      );
      final before = old.Admission();
      await before.record(route);
      before.rejectOutput();
      await before.settleOpeningTracks();
      expect(
        before.failure,
        isNotNull,
        reason: '106 returned normally despite the pending asynchronous error',
      );
      final after = current.Admission();
      await after.record(route);
      after.rejectOutput();
      await expectLater(
        after.settleOpeningTracks(),
        throwsA(isA<AppFailure>()),
      );
      expect(after.failure, before.failure);
      expect(after.established, false);
    },
  );
}
