import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/library_events.dart';
import 'core_test.dart' show response, syntheticSession;
import 'library_events_056_test.dart' show Wire;

void main() {
  for (final pendingBatch in [true, false]) {
    testWidgets(
      'library notification ID budget is bounded, pendingBatch=$pendingBatch',
      (tester) async {
        final api = EmbyClient(
          client: MockClient((_) async => response('{}', 500)),
        )..session = syntheticSession();
        final wire = Wire(), hold = Completer<void>();
        var calls = 0, ids = 0;
        final events = LibraryEvents(
          api,
          connect: (_) async => wire.channel,
          coalesce: const Duration(seconds: 1),
          onChanges: (removed, added) async {
            calls++;
            ids += removed.length + added.length;
            if (calls == 1) await hold.future;
          },
        );
        events.setActive(true);
        await tester.pump();
        if (!pendingBatch) {
          wire.change(removed: ['first']);
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
        }
        for (var i = 0; i < 20 && wire.closes == 0; i++) {
          wire.change(removed: List.generate(10000, (j) => 'batch${i}item$j'));
          await tester.pump();
          if (!pendingBatch) await tester.pump(const Duration(seconds: 1));
        }
        expect(wire.closes, 1);
        hold.complete();
        await tester.pump();
        await events.settled;
        events.dispose();
        api.close();
        await tester.pump();
        expect(ids, pendingBatch ? 20000 : 100001);
      },
    );
  }
  testWidgets('disposing a slow notification drain drops queued actions', (
    tester,
  ) async {
    final api = EmbyClient(client: MockClient((_) async => response('{}', 500)))
      ..session = syntheticSession();
    final wire = Wire(), hold = Completer<void>();
    var calls = 0;
    final events = LibraryEvents(
      api,
      connect: (_) async => wire.channel,
      coalesce: Duration.zero,
      onChanges: (removed, added) async {
        calls++;
        await hold.future;
      },
    );
    events.setActive(true);
    await tester.pump();
    for (final id in ['inflight', 'queued']) {
      wire.change(removed: [id]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
    }
    events.dispose();
    hold.complete();
    await tester.pump();
    await events.settled;
    api.close();
    await tester.pump();
    expect(calls, 1);
  });
  testWidgets(
    'slow library storage retains one drain and coalesces identical pending batches',
    (tester) async {
      final api = EmbyClient(
        client: MockClient((_) async => response('{}', 500)),
      )..session = syntheticSession();
      final wire = Wire(), hold = Completer<void>();
      final calls = <Set<String>>[], futures = <Future<void>>{};
      final events = LibraryEvents(
        api,
        connect: (_) async => wire.channel,
        coalesce: const Duration(milliseconds: 1),
        onChanges: (removed, added) async {
          calls.add(removed);
          if (calls.length == 1) await hold.future;
        },
      );
      events.setActive(true);
      await tester.pump();
      wire.change(removed: ['first']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2));
      for (var i = 0; i < 500; i++) {
        wire.change(removed: ['repeated']);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2));
        futures.add(events.settled);
      }
      hold.complete();
      await tester.pump();
      await events.settled;
      events.dispose();
      api.close();
      await tester.pump();
      expect(calls, [
        {'first'},
        {'repeated'},
      ]);
      expect(futures.length, 1);
    },
  );
  testWidgets(
    'distinct library batches keep order and an excessive stalled queue disconnects',
    (tester) async {
      final api = EmbyClient(
        client: MockClient((_) async => response('{}', 500)),
      )..session = syntheticSession();
      final wire = Wire(), hold = Completer<void>();
      final calls = <String>[];
      final events = LibraryEvents(
        api,
        connect: (_) async => wire.channel,
        coalesce: const Duration(milliseconds: 1),
        onChanges: (removed, added) async {
          calls.add('${removed.join(',')}|${added.join(',')}');
          if (calls.length == 1) await hold.future;
        },
      );
      events.setActive(true);
      await tester.pump();
      wire.change(removed: ['first']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2));
      for (var i = 0; i < 200 && wire.closes == 0; i++) {
        wire.change(
          removed: i.isEven ? ['same'] : [],
          added: i.isOdd ? ['same'] : [],
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2));
      }
      final disconnected = wire.closes;
      hold.complete();
      await tester.pump();
      await events.settled;
      events.dispose();
      api.close();
      await tester.pump();
      expect(disconnected, 1);
      expect(calls.length, lessThanOrEqualTo(65));
      for (var i = 1; i < calls.length; i++) {
        expect(calls[i], i.isOdd ? 'same|' : '|same');
      }
    },
  );
}
