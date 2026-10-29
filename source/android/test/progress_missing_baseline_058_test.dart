import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show syntheticSession, response;

MediaItem missingEpisode() => MediaItem({
  'Id': 'missing-episode',
  'Type': 'Episode',
  'SeriesId': 'series',
  'UserData': {
    'PlaybackPositionTicks': 0,
    'Played': false,
    'PlayCount': 0,
    'IsFavorite': false,
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final completed in [false, true]) {
    test(
      '${completed ? 'completed' : 'partial'} missing resource pauses across retries and restart',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final store = AppStore(prefs);
        await store.log.setEnabled(false);
        final account = syntheticSession();
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((r) async {
            calls++;
            return response('{}', completed ? 410 : 404);
          }),
        )..session = account;
        if (completed) {
          await store.completions.remember(
            account,
            missingEpisode(),
            const Duration(minutes: 5),
          );
        } else {
          await store.saveProgress(
            account,
            missingEpisode().id,
            const Duration(seconds: 70),
            serverBaseline: missingEpisode(),
          );
        }
        Future<void> retry(AppStore value) => completed
            ? value.completions.retry(api, account)
            : value.retryPendingProgress(api, account);
        for (var i = 0; i < 6; i++) {
          await retry(store);
        }
        final restarted = AppStore(prefs);
        await retry(restarted);
        expect(
          calls,
          1,
          reason:
              'Missing resource must not be periodically probed, including after restart',
        );
        if (completed) {
          expect(
            restarted.completions.pending(account, missingEpisode().id),
            isTrue,
          );
        } else {
          expect(
            restarted.localProgress(account, missingEpisode().id),
            const Duration(seconds: 70),
          );
        }
        api.close();
        store.log.dispose();
        restarted.log.dispose();
        store.dispose();
        restarted.dispose();
      },
    );
  }
  test(
    'known deleted resources cause zero partial and completed retry requests',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      final account = syntheticSession();
      await store.saveProgress(account, 'partial', const Duration(seconds: 70));
      await store.completions.remember(
        account,
        missingEpisode(),
        const Duration(minutes: 5),
      );
      await store.homeOrder.removals.apply(
        account,
        removed: {'partial', missingEpisode().id},
      );
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          calls++;
          return response(jsonEncode(missingEpisode().data), 200);
        }),
      )..session = account;
      await store.retryPendingProgress(api, account);
      await store.completions.retry(api, account);
      expect(calls, 0);
      expect(
        store.localProgress(account, 'partial'),
        const Duration(seconds: 70),
      );
      expect(store.completions.pending(account, missingEpisode().id), isTrue);
      api.close();
      store.log.dispose();
      store.dispose();
    },
  );
}
