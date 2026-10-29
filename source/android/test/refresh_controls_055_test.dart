import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show syntheticSession;

class WarmupTransport extends http.BaseClient {
  final entered = Completer<void>();
  bool aborted = false, holdCatalogue = true;
  int catalogues = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final catalogue = request.url.path.endsWith('/Items');
    if (catalogue) {
      catalogues++;
      if (holdCatalogue) {
        if (!entered.isCompleted) entered.complete();
        await (request as http.Abortable).abortTrigger;
        aborted = true;
        holdCatalogue = false;
        throw http.RequestAbortedException(request.url);
      }
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"Items":[],"TotalRecordCount":0}')),
      200,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'manual refresh cancels irrelevant warmup and finishes without its timeout',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          transport = WarmupTransport();
      final api = EmbyClient(client: transport)..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      final store = AppStore(prefs),
          feed = HomeFeed(
            api,
            AppStore(prefs),
            browse: repo,
            preloadSearch: true,
          );
      final warm = repo.warmSearchCatalogue();
      await transport.entered.future;
      await feed
          .refresh(force: true, reconcile: true)
          .timeout(const Duration(seconds: 3));
      await warm;
      expect(transport.aborted, true);
      expect(repo.failures, 0);
      expect(api.backgroundWork.paused, false);
      expect(feed.error, isNull);
      transport.holdCatalogue = false;
      await repo.catalogue();
      expect(
        transport.catalogues,
        2,
        reason: 'a foreground search can retry normally',
      );
      feed.dispose();
      feed.store.dispose();
      store.dispose();
      repo.dispose();
      api.close();
    },
  );
  test(
    'global background pause still aborts the independent warmup scope',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          transport = WarmupTransport();
      final api = EmbyClient(client: transport)..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      final warm = repo.warmSearchCatalogue();
      await transport.entered.future;
      repo.suspend();
      await warm;
      expect(transport.aborted, true);
      expect(repo.peekSharedCatalogue(null), isNull);
      expect(repo.failures, 0);
      repo.dispose();
      api.close();
    },
  );
  test('ID batches obey both item count and encoded URL budget', () {
    for (final values in [
      List.generate(2000, (i) => '$i'),
      List.generate(501, (i) => 'a-longer-real-id-$i-${'x' * 45}'),
    ]) {
      final batches = itemLookupBatches(values).toList();
      expect(batches.expand((b) => b), values);
      for (final batch in batches) {
        expect(batch.length, lessThanOrEqualTo(500));
        expect(
          Uri(queryParameters: {'Ids': batch.join(',')}).query.length,
          lessThanOrEqualTo(5504),
        );
      }
    }
  });
  test(
    'confirmed fresh IDs skip lookup without evicting missing unconfirmed metadata',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final api = EmbyClient(client: WarmupTransport()..holdCatalogue = false)
        ..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      await repo.cache.put(
        repo.key('detail:live'),
        ItemPage([
          MediaItem({'Id': 'live'}),
        ], 1),
        DateTime.now(),
      );
      expect(await repo.reconcileCachedItems(confirmedIds: {'live'}), isEmpty);
      expect(repo.peek('detail:live'), isNotNull);
      repo.dispose();
      api.close();
    },
  );
}
