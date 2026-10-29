import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/release_refresh.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'retired styles normalize to traditional while four accents remain',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          store = AppStore(await SharedPreferences.getInstance());
      for (final value in VisualStyle.values) {
        await prefs.setString('yingyu.visualStyle.v1', value.name);
        expect(store.visualStyle, VisualStyle.traditional);
        await store.setVisualStyle(value);
        expect(prefs.getString('yingyu.visualStyle.v1'), 'traditional');
      }
      expect(AppAccent.available, [
        AppAccent.lilac,
        AppAccent.bay,
        AppAccent.emerald,
        AppAccent.blush,
      ]);
      for (final retired in ['titanium', 'pearl']) {
        await prefs.setString('yingyu.accent.v1', retired);
        expect(store.accent, AppAccent.lilac);
      }
      store.dispose();
    },
  );
  testWidgets(
    'manual refresh keeps a spinner in the pull gap without hiding header loading',
    (tester) async {
      final gate = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        CupertinoApp(
          home: ReleaseRefreshScrollView(
            onRefresh: () {
              calls++;
              return gate.future;
            },
            slivers: const [
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 1600,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: CupertinoActivityIndicator(
                      key: Key('header-loading'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      final gesture = await tester.startGesture(const Offset(200, 150));
      await gesture.moveBy(const Offset(0, 160));
      await tester.pump();
      expect(find.text('松手刷新'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(calls, 1);
      final spinner = find.byKey(const Key('pull-refresh-loading'));
      expect(spinner, findsOneWidget);
      expect(find.byKey(const Key('header-loading')), findsOneWidget);
      expect(
        tester.getRect(spinner).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const Key('header-loading'))).top,
        ),
      );
      gate.complete();
      await tester.pump(const Duration(seconds: 1));
      expect(spinner, findsNothing);
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
