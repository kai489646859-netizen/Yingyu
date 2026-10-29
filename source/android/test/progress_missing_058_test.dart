import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/log_export.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response;
import 'progress_missing_baseline_058_test.dart' show missingEpisode;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  final account = syntheticSession();
  final entry = missingEpisode();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
  });
  tearDown(() {
    store.log.dispose();
    store.dispose();
  });
  Future<void> pending() => store.saveProgress(
    account,
    entry.id,
    const Duration(seconds: 70),
    serverBaseline: entry,
  );

  test(
    'suspended ID does not starve a live pending episode or flood log',
    () async {
      await pending();
      await store.saveProgress(
        account,
        'survivor',
        const Duration(seconds: 70),
      );
      final calls = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          final id = r.url.path.split('/').last;
          calls.add(id);
          return id == entry.id
              ? response('{}', 404)
              : response(
                  jsonEncode({
                    'Id': id,
                    'UserData': {
                      'PlaybackPositionTicks': ticks(
                        const Duration(seconds: 70),
                      ),
                    },
                  }),
                  200,
                );
        }),
      )..session = account;
      await store.retryPendingProgress(api, account);
      final before = store.log.entries.length;
      for (var i = 0; i < 20; i++) {
        await store.retryPendingProgress(api, account);
      }
      expect(calls, [entry.id, 'survivor']);
      expect(store.log.entries.length, before);
      expect(store.localProgress(account, 'survivor'), isNull);
      expect(
        store.homeOrder.removals.ids(account),
        isEmpty,
        reason: '404 pauses work; it does not globally delete media',
      );
      expect(store.log.entries.map((e) => e.message).join(), contains('资源摘要='));
      expect(
        store.log.entries.map((e) => e.message).join(),
        isNot(contains(entry.id)),
      );
      api.close();
    },
  );

  for (final status in [401, 403, 429, 500]) {
    test(
      'HTTP $status keeps recovery possible and does not classify as deleted',
      () async {
        await pending();
        var code = status, calls = 0;
        final api = EmbyClient(
          client: MockClient((r) async {
            calls++;
            return response(
              code == 200
                  ? jsonEncode({
                      ...entry.data,
                      'UserData': {
                        'PlaybackPositionTicks': ticks(
                          const Duration(seconds: 70),
                        ),
                      },
                    })
                  : '{}',
              code,
            );
          }),
        )..session = account;
        await store.retryPendingProgress(api, account);
        code = 200;
        await store.retryPendingProgress(api, account);
        expect(calls, 2);
        expect(store.localProgress(account, entry.id), isNull);
        api.close();
      },
    );
  }

  test(
    'fresh resource snapshot restores a paused episode, cache reuse does not',
    () async {
      await pending();
      var online = false, calls = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          calls++;
          if (r.url.path.endsWith('/Items')) {
            return response(
              jsonEncode({
                'Items': [entry.data],
                'TotalRecordCount': 1,
              }),
              200,
            );
          }
          return online
              ? response(
                  jsonEncode({
                    ...entry.data,
                    'UserData': {
                      'PlaybackPositionTicks': ticks(
                        const Duration(seconds: 70),
                      ),
                    },
                  }),
                  200,
                )
              : response('{}', 404);
        }),
      )..session = account;
      final repo = BrowseRepository(
        api,
        store.browseCache,
        BrowsePreferences(store.prefs),
        visibility: store.homeOrder,
        spacing: Duration.zero,
      );
      await store.browseCache.put(
        repo.key('synthetic'),
        ItemPage([entry], 1),
        DateTime.now(),
      );
      await store.retryPendingProgress(api, account);
      await repo.read(
        'synthetic',
        () => throw StateError('cache must avoid network'),
      );
      await store.retryPendingProgress(api, account);
      expect(calls, 1);
      online = true;
      await repo.catalogue(force: true, resourceSnapshot: true);
      await store.retryPendingProgress(api, account);
      expect(
        calls,
        3,
        reason:
            'One missing detail, normal directory, one retry; no restoration probes',
      );
      expect(store.localProgress(account, entry.id), isNull);
      repo.dispose();
      api.close();
    },
  );

  test('same ID on another server is not paused', () async {
    await pending();
    final other = syntheticSession('http://127.0.0.1:19');
    await store.saveProgress(other, entry.id, const Duration(seconds: 70));
    var calls = 0;
    final api = EmbyClient(
      client: MockClient((r) async {
        calls++;
        return response('{}', 404);
      }),
    )..session = account;
    await store.retryPendingProgress(api, account);
    api.session = other;
    await store.retryPendingProgress(api, other);
    expect(calls, 2);
    api.close();
  });

  for (final completed in [false, true]) {
    test(
      'deletion arriving during ${completed ? 'completed' : 'partial'} read prevents write and acknowledgement',
      () async {
        if (completed) {
          await store.completions.remember(
            account,
            entry,
            const Duration(minutes: 5),
          );
        } else {
          await pending();
        }
        final result = Completer<http.Response>(), started = Completer<void>();
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((r) {
            calls++;
            started.complete();
            return result.future;
          }),
        )..session = account;
        final job = completed
            ? store.completions.retry(api, account)
            : store.retryPendingProgress(api, account);
        await started.future;
        await store.homeOrder.removals.apply(account, removed: {entry.id});
        result.complete(response(jsonEncode(entry.data), 200));
        await job;
        expect(calls, 1);
        if (completed) {
          expect(store.completions.pending(account, entry.id), isTrue);
        } else {
          expect(
            store.localProgress(account, entry.id),
            const Duration(seconds: 70),
          );
        }
        api.close();
      },
    );
  }

  test('late 404 cannot override a newer existence confirmation', () async {
    await pending();
    final result = Completer<http.Response>(), started = Completer<void>();
    var calls = 0;
    final api = EmbyClient(
      client: MockClient((r) {
        calls++;
        started.complete();
        return result.future;
      }),
    )..session = account;
    final job = store.retryPendingProgress(api, account);
    await started.future;
    await store.homeOrder.removals.apply(account, added: {entry.id});
    result.complete(response('{}', 404));
    await job;
    expect(
      store.homeOrder.removals.progressAllowed(account, entry.id, store.log),
      isTrue,
    );
    expect(calls, 1);
    api.close();
  });

  test('unsupported UserData 404 is not mistaken for missing item', () async {
    await pending();
    final calls = <String>[];
    final api = EmbyClient(
      client: MockClient((r) async {
        calls.add(r.method);
        return r.method == 'POST'
            ? response('{}', 404)
            : response(jsonEncode(entry.data), 200);
      }),
    )..session = account;
    await store.retryPendingProgress(api, account);
    expect(calls, ['GET', 'POST']);
    expect(
      store.homeOrder.removals.progressAllowed(account, entry.id, store.log),
      isTrue,
    );
    api.close();
  });

  test(
    'operation labels never include IDs, search words, tokens or addresses',
    () async {
      final paths = {
        'Users/private-user/Items/private-item': '影片详情',
        'Users/private-user/Items?SearchTerm=private-title&api_key=secret':
            '影片搜索',
        'Users/private-user/Views': '媒体库入口',
        'Users/private-user/Items?Recursive=true': '媒体目录',
        'Users/private-user/Items/Resume': '继续观看列表',
      };
      for (final item in paths.entries) {
        expect(
          metadataOperation(
            Uri.parse('https://private-host.invalid/emby/${item.key}'),
          ),
          item.value,
        );
      }
    },
  );

  test(
    'export distinguishes mixed versions and freezes summary with selection',
    () {
      final log = DiagnosticLog(
        restored: [
          LogEntry(DateTime(2026), '0.5.7', LogArea.api, LogLevel.error, 'old'),
          LogEntry(
            DateTime(2026, 1, 2),
            appVersion,
            LogArea.progress,
            LogLevel.warning,
            'current',
            buildCode: androidVersionCode,
          ),
        ],
      );
      final snapshot = LogExportSnapshot(log);
      log.add(LogArea.api, 'new');
      expect(snapshot.header, contains('0.5.7=1 条'));
      expect(
        snapshot.header,
        contains('当前构建 $appVersion/code$androidVersionCode：1 条'),
      );
      expect(snapshot.header, contains('错误=0 条；警告=1 条'));
      expect(
        LogExportSnapshot(log, selection: {log.entries.first}).header,
        contains('当前构建 $appVersion/code$androidVersionCode：0 条'),
      );
      log.dispose();
    },
  );
}
