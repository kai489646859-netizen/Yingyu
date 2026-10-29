// The 139 direct-Path experiment remains archived in its complete delivery.
// These cases now guard against repeating that route-selection regression.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'core_test.dart' show syntheticSession;
import 'startup_test.dart' show sourceFor, detailFor;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final flag in [true, false, null]) {
    test(
      'Path is not promoted from DirectPlay capability alone: $flag',
      () async {
        final api = EmbyClient(
          client: MockClient((_) async => throw StateError('No negotiation')),
        )..session = syntheticSession();
        addTearDown(api.close);
        final route = await api.preparePlayback(
          detailFor({
            ...sourceFor('mp4'),
            'Protocol': 'Http',
            'IsRemote': true,
            'SupportsDirectPlay': flag,
            'Path': 'https://server-only.invalid:12366/input.mp4',
          }),
        );
        expect(route.url, contains('/Videos/movie/stream.mp4'));
        expect(route.playMethod, 'DirectStream');
      },
    );
  }
  test(
    'static route retains selected source and independent sessions',
    () async {
      final api = EmbyClient(
        client: MockClient((_) async => throw StateError('No negotiation')),
      )..session = syntheticSession();
      addTearDown(api.close);
      final first = {
        ...sourceFor('mp4'),
        'Protocol': 'Http',
        'IsRemote': true,
        'SupportsDirectPlay': true,
        'Path': 'https://server-only.invalid:12366/first.mp4',
      };
      final second = {
        ...first,
        'Id': 'chosen',
        'Path': 'https://server-only.invalid:12366/chosen.mp4',
      };
      final detail = detailFor(first);
      detail.data['MediaSources'] = [first, second];
      final a = await api.preparePlayback(detail, sourceId: 'chosen');
      final b = await api.preparePlayback(detail, sourceId: 'chosen');
      expect(a.sourceId, 'chosen');
      expect(Uri.parse(a.url).queryParameters['MediaSourceId'], 'chosen');
      expect(a.sessionId, isNot(b.sessionId));
    },
  );
}
