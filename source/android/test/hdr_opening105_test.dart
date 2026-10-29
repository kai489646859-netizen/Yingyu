import 'package:flutter_test/flutter_test.dart';
import 'host/hdr105_current_opening.dart' as current;
import 'host/hdr105_old_opening.dart' as old;
import 'package:yingyu/core/models.dart';

void main() {
  test(
    'complete admission settles initial tracks before the final HDR refill',
    () async {
      // The fixture reproduces the observed sid refresh invalidating a previously
      // refilled queue; it does not simulate or prove TrueHD decoder corruption.
      final route = PlaybackRoute(
        url: 'https://example.invalid/movie.mkv',
        sourceId: 'source',
        sessionId: 'session',
        headers: {},
        streams: [],
      );
      final dynamic f = const bool.fromEnvironment('OLD_ADMISSION')
          ? old.Admission()
          : current.Admission();
      await f.record(route);
      expect(f.prepareTracksWhilePaused, true);
      f.selectSubtitle();
      await f.settleOpeningTracks();
      expect(f.established, true);
      expect(
        f.cleanOpening,
        true,
        reason: 'A late sid switch must not invalidate the final HDR refill',
      );
      expect(f.calls, ['sid', 'hdr-refill']);
    },
  );
}
