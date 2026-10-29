import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/offline_translation.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/offline_translation.dart';
import 'core_test.dart' show syntheticSession;

class FakeTranslation implements TranslationPlatform {
  TranslationStatus value = const TranslationStatus(ready: true);
  int downloads = 0, translations = 0, reads = 0;
  bool? wifi;
  Completer<String>? gate;
  Object? failure;
  @override
  Future<TranslationStatus> status() async {
    reads++;
    return value;
  }

  @override
  Future<TranslationStatus> download({required bool wifiOnly}) async {
    downloads++;
    wifi = wifiOnly;
    return value = const TranslationStatus(phase: 'waiting_wifi');
  }

  @override
  Future<TranslationStatus> delete() async => value = const TranslationStatus();
  @override
  Future<String> translate(String text) async {
    translations++;
    if (failure != null) throw failure!;
    return gate == null ? '离线译文：$text' : gate!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const english = 'A traveller discovers a secret on a distant island.';
  late SharedPreferences prefs;
  late FakeTranslation native;
  late OfflineTranslation service;
  final account = syntheticSession();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    native = FakeTranslation();
    service = OfflineTranslation(prefs, platform: native);
  });
  tearDown(() => service.dispose());
  Future<String> translate([String text = english]) =>
      service.translate(account, 'film', text, TranslationRequest());
  test('reading state or translation never downloads a model', () async {
    expect(service.automatic, true);
    expect(service.wifiOnly, true);
    await service.refresh();
    await translate();
    expect(native.downloads, 0);
  });
  test('missing model remains missing until explicit user download', () async {
    native.value = const TranslationStatus();
    await expectLater(translate(), throwsA(isA<AppFailure>()));
    expect(native.downloads, 0);
    expect(native.translations, 0);
    await service.download();
    expect(native.downloads, 1);
    expect(native.wifi, true);
    expect(service.status.label, '等待 Wi-Fi');
  });
  test('mobile data opt in persists without starting a download', () async {
    await service.setWifiOnly(false);
    await service.setAutomatic(true);
    expect(native.downloads, 0);
    final copy = OfflineTranslation(prefs, platform: native);
    expect(copy.wifiOnly, false);
    expect(copy.automatic, true);
    await service.setAutomatic(false);
    expect(copy.automatic, false);
    await copy.download();
    expect(native.wifi, false);
    copy.dispose();
  });
  test('cache is separated by server user real ID and original text', () async {
    final result = await translate();
    expect(await translate(), result);
    expect(native.translations, 1);
    expect(
      service.cached(syntheticSession('http://127.0.0.1:10'), 'film', english),
      isNull,
    );
    final other = Session(
      base: account.base,
      userId: 'other',
      username: 'other',
      token: 'other-token',
      deviceId: account.deviceId,
    );
    expect(service.cached(other, 'film', english), isNull);
    expect(service.cached(account, 'version2', english), isNull);
    expect(service.cached(account, 'film', '$english changed'), isNull);
    expect(
      prefs.getString(OfflineTranslation.cacheKey),
      isNot(contains(account.token)),
    );
    expect(
      prefs.getString(OfflineTranslation.cacheKey),
      isNot(contains(account.base.toString())),
    );
    await translate('$english changed');
    expect(native.translations, 2);
  });
  test(
    'deleting model preserves cached translation and clearing text preserves model',
    () async {
      await translate();
      await service.deleteModel();
      expect(await translate(), contains('离线译文'));
      expect(native.translations, 1);
      native.value = const TranslationStatus(ready: true);
      await service.clearCache();
      await service.refresh();
      expect(service.cacheBytes, 0);
      expect(service.status.ready, true);
    },
  );
  test('cancelled page does not receive or cache late result', () async {
    native.gate = Completer<String>();
    final request = TranslationRequest();
    final work = service.translate(account, 'film', english, request);
    await Future<void>.delayed(Duration.zero);
    request.cancel();
    final assertion = expectLater(work, throwsA(isA<TranslationCancelled>()));
    native.gate!.complete('迟到译文');
    await assertion;
    expect(service.cacheBytes, 0);
  });
  test(
    'clear cache during inference does not repopulate removed cache',
    () async {
      native.gate = Completer<String>();
      final work = translate();
      await Future<void>.delayed(Duration.zero);
      await service.clearCache();
      native.gate!.complete('结果');
      await work;
      expect(service.cacheBytes, 0);
    },
  );
  test('delete during inference invalidates late completion', () async {
    native.gate = Completer<String>();
    final work = translate();
    await Future<void>.delayed(Duration.zero);
    await service.deleteModel();
    final assertion = expectLater(work, throwsA(isA<TranslationCancelled>()));
    native.gate!.complete('旧结果');
    await assertion;
    expect(service.cacheBytes, 0);
  });
  test('corrupt cache is not silently erased', () async {
    await prefs.setString(OfflineTranslation.cacheKey, 'invalid');
    await expectLater(translate(), throwsA(isA<AppFailure>()));
    expect(prefs.getString(OfflineTranslation.cacheKey), 'invalid');
    await service.clearCache();
    await translate();
  });
  test(
    'language and inference failures remain visible and do not cache',
    () async {
      native.failure = PlatformException(code: 'not_english');
      await expectLater(translate(), throwsA(isA<PlatformException>()));
      expect(service.cacheBytes, 0);
      expect(native.downloads, 0);
      expect(OfflineTranslation.candidate('这是完整的中文剧情简介。'), false);
      expect(OfflineTranslation.candidate(''), false);
    },
  );
  test('bounded cache keeps latest 200 real media entries', () async {
    for (var i = 0; i < 203; i++) {
      await service.translate(account, 'film$i', english, TranslationRequest());
    }
    expect(service.cached(account, 'film0', english), isNull);
    expect(service.cached(account, 'film202', english), isNotNull);
    expect(
      service.cacheBytes,
      lessThanOrEqualTo(OfflineTranslation.cacheLimit),
    );
  });
  Widget synopsis({bool active = true}) => MaterialApp(
    home: Scaffold(
      body: SynopsisTranslation(
        service: service,
        account: account,
        item: MediaItem({'Id': 'film', 'Overview': english}),
        style: const TextStyle(fontSize: 14),
        currentAccount: () => true,
        active: active,
      ),
    ),
  );
  testWidgets('manual translation original toggle and attribution', (
    tester,
  ) async {
    service.dispose();
    service = OfflineTranslation(prefs, platform: native);
    await service.setAutomatic(false);
    await tester.pumpWidget(synopsis());
    await tester.pump();
    expect(native.translations, 0);
    await tester.tap(find.text('翻译'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    for (var n = 0; n < 20; n++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.text('查看原文'),
      findsOneWidget,
      reason:
          'translate=${native.translations}; reads=${native.reads}; cache=${service.cacheBytes}; texts=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
    );
    await tester.pumpAndSettle();
    expect(find.text('查看原文'), findsOneWidget);
    expect(find.byType(TranslationBadge), findsOneWidget);
    expect(
      find.byKey(const Key('translation-accuracy-notice')),
      findsOneWidget,
    );
    await tester.tap(find.text('查看原文'));
    await tester.pump();
    expect(find.text(english), findsOneWidget);
    expect(native.translations, 1);
  });
  testWidgets(
    'download requires visible button and confirmation; settings and cancel never download',
    (tester) async {
      service.dispose();
      service = OfflineTranslation(prefs, platform: native);
      native.value = const TranslationStatus();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [OfflineTranslationGroup(service: service)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(native.downloads, 0);
      await tester.tap(find.text('英语简介 → 中文'));
      await tester.pump();
      expect(native.downloads, 0);
      await tester.tap(find.byKey(const Key('translation-download')));
      await tester.pumpAndSettle();
      expect(find.text('下载离线语言包？'), findsOneWidget);
      expect(native.downloads, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(native.downloads, 0);
      await tester.tap(find.byKey(const Key('translation-download')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('translation-confirm-download')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(native.downloads, 1);
      expect(native.wifi, true);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'long download keeps its status and indeterminate bar without an elapsed block',
    (tester) async {
      service.dispose();
      service = OfflineTranslation(prefs, platform: native);
      native.value = const TranslationStatus(
        phase: 'downloading',
        elapsed: Duration(minutes: 3),
        network: '当前使用 Wi-Fi',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [OfflineTranslationGroup(service: service)],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('已等待'), findsNothing);
      expect(find.byKey(const Key('translation-task-status')), findsNothing);
      expect(find.textContaining('等待较久'), findsNothing);
      expect(find.text('下载说明'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
      expect(native.downloads, 0);
      native.value = const TranslationStatus(
        ready: true,
        elapsed: Duration(minutes: 4),
      );
      await service.refresh();
      await tester.pump();
      expect(find.text('已等待 3 分 0 秒'), findsNothing);
      expect(find.textContaining('本次任务耗时'), findsNothing);
      expect(find.byKey(const Key('translation-task-status')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('automatic without model settles and never downloads', (
    tester,
  ) async {
    service.dispose();
    service = OfflineTranslation(prefs, platform: native);
    native.value = const TranslationStatus();
    expect(service.automatic, true);
    await tester.pumpWidget(synopsis());
    await tester.pumpAndSettle();
    expect(native.downloads, 0);
    expect(native.translations, 0);
    expect(native.reads, lessThan(4));
    expect(find.text(english), findsOneWidget);
  });
  testWidgets('hidden detail does not automatically translate until visible', (
    tester,
  ) async {
    service.dispose();
    service = OfflineTranslation(prefs, platform: native);
    await service.setAutomatic(true);
    await tester.pumpWidget(synopsis(active: false));
    await tester.pumpAndSettle();
    expect(native.translations, 0);
    await tester.pumpWidget(synopsis());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(native.translations, 1);
  });
}
