import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/ui/release_refresh.dart';

void main() {
  testWidgets('threshold is a prompt; only release commits once', (
    tester,
  ) async {
    var requests = 0;
    final gate = Completer<void>();
    await tester.pumpWidget(
      CupertinoApp(
        home: ReleaseRefreshScrollView(
          onRefresh: () {
            requests++;
            return gate.future;
          },
          slivers: const [SliverToBoxAdapter(child: SizedBox(height: 1500))],
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(200, 250));
    await gesture.moveBy(const Offset(0, 450));
    await tester.pump();
    expect(find.text('松手刷新'), findsOneWidget);
    expect(requests, 0);
    await gesture.up();
    await tester.pump();
    expect(requests, 1);
    expect(find.text('正在刷新'), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('正在刷新'), findsNothing);
  });

  for (final canceled in [false, true]) {
    testWidgets(
      canceled
          ? 'pointer cancellation never refreshes'
          : 'cross threshold then retreat before release cancels',
      (tester) async {
        var requests = 0;
        await tester.pumpWidget(
          CupertinoApp(
            home: ReleaseRefreshScrollView(
              onRefresh: () async {
                requests++;
              },
              slivers: const [
                SliverToBoxAdapter(child: SizedBox(height: 1500)),
              ],
            ),
          ),
        );
        final gesture = await tester.startGesture(const Offset(200, 100));
        await gesture.moveBy(const Offset(0, 450));
        await tester.pump();
        expect(find.text('松手刷新'), findsOneWidget);
        if (canceled) {
          await gesture.cancel();
        } else {
          for (var n = 0; n < 50; n++) {
            await gesture.moveBy(const Offset(0, -12));
            await tester.pump(const Duration(milliseconds: 8));
          }
          expect(
            find.text('松手刷新'),
            findsNothing,
            reason:
                'pull=${(tester.state(find.byType(ReleaseRefresh)) as dynamic).pull}; pixels=${tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels}',
          );
          await gesture.up();
        }
        await tester.pumpAndSettle();
        expect(requests, 0);
      },
    );
  }
}
