import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/personal_library.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/intro_editor.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'core_test.dart' show syntheticSession;
import 'personal_features_test.dart' show featureEpisode, featureMovie;
import 'playback_test.dart' show FakeBackend;

class EditorBackend extends FakeBackend {
  final seeks = <Duration>[];
  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    await super.seek(value);
  }
}

void main() {
  late AppStore store;
  late EmbyClient api;
  late PlaybackSession session;
  late EditorBackend backend;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    await store.log.setEnabled(false);
    api = EmbyClient(
      client: MockClient(
        (_) async => throw StateError('media and API access forbidden'),
      ),
    )..session = syntheticSession();
  });

  Future<void> show(WidgetTester tester, {MediaItem? item}) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    backend = EditorBackend()
      ..snapshot = const PlaybackSnapshot(duration: Duration(minutes: 10));
    session = PlaybackSession(
      api: api,
      store: store,
      item: item ?? featureEpisode('1'),
      backend: backend,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSurface(
              context,
              (_) => IntroEditor(session: session),
              playerMenu: true,
            ),
            child: const Text('编辑'),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await session.close();
      session.dispose();
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    });
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      70,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  Future<void> save(WidgetTester tester) async {
    await reveal(tester, find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
  }

  Future<void> editIntro(WidgetTester tester) async {
    await reveal(tester, find.byKey(const ValueKey('skip-edit-intro')));
    await tester.tap(find.byKey(const ValueKey('skip-edit-intro')));
    await tester.pump();
  }

  testWidgets(
    'editor saves explicit whole-series intro and relative credits without seeking',
    (tester) async {
      await show(tester);
      expect(find.byType(CupertinoTextField), findsNothing);
      expect(find.byKey(const ValueKey('skip-manual-intro')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('skip-scope-series')));
      await editIntro(tester);
      await tester.enterText(find.byType(CupertinoTextField).at(0), '0:05');
      await tester.enterText(find.byType(CupertinoTextField).at(1), '1:10');
      await tester.tap(find.byKey(const ValueKey('skip-auto-intro')));
      await reveal(tester, find.byKey(const ValueKey('skip-credits-enabled')));
      await tester.tap(find.byKey(const ValueKey('skip-credits-enabled')));
      await tester.pump();
      await reveal(tester, find.text('片尾开始时的剩余时长'));
      await tester.enterText(find.byType(CupertinoTextField).last, '1:20');
      await reveal(tester, find.byKey(const ValueKey('skip-auto-credits')));
      await tester.tap(find.byKey(const ValueKey('skip-auto-credits')));
      await save(tester);
      final saved = store.personal.resolveSkipRule(
        api.session!,
        featureEpisode('2', season: 's2'),
      )!;
      expect(saved.scope, SkipScope.series);
      expect(saved.rule.intro!.start.inSeconds, 5);
      expect(saved.rule.intro!.end.inSeconds, 70);
      expect(saved.rule.creditsRemaining!.inSeconds, 80);
      expect(saved.rule.autoIntro, isTrue);
      expect(saved.rule.autoCredits, isTrue);
      expect(backend.seeks, isEmpty);
      expect(session.position, Duration.zero);
      expect(find.text('编辑'), findsOneWidget);
    },
  );

  testWidgets('movie offers current movie scope and stays manual by default', (
    tester,
  ) async {
    await show(tester, item: featureMovie('movie'));
    expect(find.text('当前影片'), findsOneWidget);
    expect(find.byKey(const ValueKey('skip-scope-season')), findsNothing);
    expect(find.byKey(const ValueKey('skip-scope-series')), findsNothing);
    await save(tester);
    final saved = PersonalLibrary(
      store.prefs,
    ).resolveSkipRule(api.session!, featureMovie('movie'))!;
    expect(saved.scope, SkipScope.item);
    expect(saved.rule.autoIntro, isFalse);
    expect(saved.rule.autoCredits, isFalse);
    expect(backend.seeks, isEmpty);
  });

  testWidgets(
    'legacy season number rule can be edited restored and removed from the panel',
    (tester) async {
      final item = MediaItem({...featureEpisode('1').data}..remove('SeasonId'));
      await store.personal.setIntro(
        api.session!,
        item,
        const IntroRange(Duration(seconds: 10), Duration(seconds: 90)),
        const Duration(minutes: 10),
      );
      await show(tester, item: item);
      expect(find.byKey(const ValueKey('skip-scope-season')), findsOneWidget);
      await editIntro(tester);
      expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).at(0))
            .controller!
            .text,
        '0:10',
      );
      await tester.enterText(find.byType(CupertinoTextField).at(1), '1:20');
      await save(tester);
      final sibling = MediaItem({...item.data, 'Id': '2'});
      expect(
        PersonalLibrary(
          store.prefs,
        ).intro(api.session!, sibling)!.end.inSeconds,
        80,
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await editIntro(tester);
      expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).at(1))
            .controller!
            .text,
        '1:20',
      );
      await reveal(tester, find.text('移除本季规则'));
      await tester.tap(find.text('移除本季规则'));
      await tester.pumpAndSettle();
      expect(
        PersonalLibrary(store.prefs).resolveSkipRule(api.session!, sibling),
        isNull,
      );
      expect(backend.seeks, isEmpty);
    },
  );

  testWidgets(
    'overlapping credits cannot be saved and keep previous durable rule',
    (tester) async {
      await show(tester);
      await reveal(tester, find.byKey(const ValueKey('skip-credits-enabled')));
      await tester.tap(find.byKey(const ValueKey('skip-credits-enabled')));
      await tester.pump();
      await reveal(tester, find.text('片尾开始时的剩余时长'));
      await tester.enterText(find.byType(CupertinoTextField).last, '9:00');
      await save(tester);
      expect(find.textContaining('片头与片尾不能重叠'), findsOneWidget);
      expect(
        store.personal.resolveSkipRule(api.session!, session.item),
        isNull,
      );
      expect(backend.seeks, isEmpty);
    },
  );

  testWidgets(
    'disabling current episode masks and deleting restores season rule',
    (tester) async {
      await store.personal.setIntro(
        api.session!,
        featureEpisode('1'),
        const IntroRange(Duration(seconds: 10), Duration(seconds: 90)),
        const Duration(minutes: 10),
      );
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('skip-scope-item')));
      await tester.tap(find.byKey(const ValueKey('skip-enabled')));
      await save(tester);
      expect(
        PersonalLibrary(
          store.prefs,
        ).resolveSkipRule(api.session!, featureEpisode('1'))!.rule.enabled,
        isFalse,
      );
      expect(
        PersonalLibrary(
          store.prefs,
        ).resolveSkipRule(api.session!, featureEpisode('2'))!.rule.enabled,
        isTrue,
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('移除本集规则'));
      await tester.tap(find.text('移除本集规则'));
      await tester.pumpAndSettle();
      expect(
        PersonalLibrary(
          store.prefs,
        ).resolveSkipRule(api.session!, featureEpisode('1'))!.scope,
        SkipScope.season,
      );
      expect(backend.seeks, isEmpty);
    },
  );

  testWidgets(
    'account changed while editor open cannot save to either account',
    (tester) async {
      await show(tester);
      final owner = session.account;
      api.session = syntheticSession();
      await save(tester);
      expect(
        PersonalLibrary(store.prefs).resolveSkipRule(owner, session.item),
        isNull,
      );
      expect(backend.seeks, isEmpty);
      expect(find.text('片头片尾'), findsOneWidget);
    },
  );
}
