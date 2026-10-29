import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'host/recovery101_current_events.dart' as current;
import 'host/recovery101_old_events.dart' as old;

void main() {
  setUp(() {
    current.InitializerNativeCallable.resetForTest();
    old.InitializerNativeCallable.resetForTest();
  });
  test(
    'complete event callback yields during a native burst before it drains',
    () async {
      final native = current.FakeMpv();
      final events = current.InitializerNativeCallable(native);
      var processed = 0, atTimer = -1;
      final ctx = await events.create((event) async {
        processed++;
      });
      native.queue.addAll(List.filled(200, 1));
      Timer.run(() {
        atTimer = processed;
      });
      events.dispatch(ctx);
      for (var n = 0; n < 20 && processed < 200; n++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(processed, 200);
      expect(atTimer, inInclusiveRange(1, 32));
      events.dispose(ctx);
      native.close();
    },
  );
  test(
    'delivered callback starves the timer until the same burst drains',
    () async {
      final native = old.FakeMpv();
      final events = old.InitializerNativeCallable(native);
      var processed = 0, atTimer = -1;
      final ctx = await events.create((event) async {
        processed++;
      });
      native.queue.addAll(List.filled(200, 1));
      Timer.run(() {
        atTimer = processed;
      });
      events.dispatch(ctx);
      await Future<void>.delayed(Duration.zero);
      expect(processed, 200);
      expect(atTimer, 200);
      events.dispose(ctx);
      native.close();
    },
  );
  test(
    'disposed callback cannot consume events belonging to a reused address',
    () async {
      final native = current.FakeMpv();
      final events = current.InitializerNativeCallable(native);
      final waiting = Completer<void>();
      final entered = Completer<void>();
      final ctx = await events.create((event) async {
        entered.complete();
        await waiting.future;
      });
      native.queue.add(1);
      events.dispatch(ctx);
      await entered.future;
      events.dispose(ctx);
      var fresh = 0;
      final replacement = await events.create((event) async {
        fresh++;
      });
      native.queue.add(1);
      final before = native.waits;
      waiting.complete();
      await Future<void>.delayed(Duration.zero);
      expect(native.waits, before);
      expect(fresh, 0);
      events.dispatch(replacement);
      await Future<void>.delayed(Duration.zero);
      expect(fresh, 1);
      events.dispose(replacement);
      native.close();
    },
  );
  test(
    'delivered callback resumes onto an address that has been reused',
    () async {
      final native = old.FakeMpv();
      final events = old.InitializerNativeCallable(native);
      final waiting = Completer<void>(), entered = Completer<void>();
      final ctx = await events.create((event) async {
        entered.complete();
        await waiting.future;
      });
      native.queue.add(1);
      events.dispatch(ctx);
      await entered.future;
      events.dispose(ctx);
      var fresh = 0;
      final replacement = await events.create((event) async {
        fresh++;
      });
      native.queue.add(1);
      waiting.complete();
      await Future<void>.delayed(Duration.zero);
      expect(fresh, 1);
      events.dispose(replacement);
      native.close();
    },
  );
}
