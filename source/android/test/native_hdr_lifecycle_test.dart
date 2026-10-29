import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/native_hdr.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yingyu/native_hdr');
  const codec = StandardMethodCodec();
  final operations = <String>[];
  String probeStatus = 'ready';
  Completer<Map<String, String>>? probeReply;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    operations.clear();
    probeStatus = 'ready';
    probeReply = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      operations.add(call.method);
      if (call.method == 'probe') {
        return probeReply == null
            ? {'status': probeStatus}
            : await probeReply!.future;
      }
      return call.method == 'watch'
          ? {
              'sdk': 34,
              'display': 0,
              'hdrTypes': [2, 3],
              'anticipatedAudioTypes': [2],
            }
          : null;
    });
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  Future<void> send(
    NativeHdrAdapter adapter,
    String method,
    Map<String, Object> value,
  ) async {
    final response = Completer<void>();
    // Test-side injection of an Android callback; no native view is loaded.
    // ignore: deprecated_member_use
    binding.defaultBinaryMessenger.handlePlatformMessage(
      'yingyu/native_hdr',
      codec.encodeMethodCall(
        MethodCall(method, {'owner': adapter.owner, ...value}),
      ),
      (_) => response.complete(),
    );
    await response.future;
    await Future<void>.delayed(Duration.zero);
  }

  Map<String, Object> surface({int token = 7, int display = 0}) => {
    'token': token,
    'width': 1920,
    'height': 1080,
    'sdk': 34,
    'display': display,
    'hdrTypes': [2, 3],
  };

  test(
    'rejected 10-bit window leaves the healthy MPV output untouched',
    () async {
      for (final status in [
        'rgb10-config',
        'egl-hdr-transfer',
        'surface-colorspace',
        'egl-window',
        'egl-exception',
        'unexpected-secret',
      ]) {
        probeStatus = status;
        final writes = <int>[];
        final adapter = NativeHdrAdapter(
          write:
              ({
                required token,
                required width,
                required height,
                required transfer,
                required fill,
              }) async {
                writes.add(token);
                return true;
              },
          active: () => true,
          message: (_) {},
          failure: fail,
        );
        await adapter.start();
        final ready = adapter.prepare('pq');
        await Future<void>.delayed(Duration.zero);
        await send(adapter, 'surface', surface());
        expect(await ready, false);
        expect(writes, isEmpty);
        expect(adapter.established, false);
        expect(await adapter.prepare('pq'), false);
        expect(writes, isEmpty);
        if (status == 'unexpected-secret') {
          expect(adapter.status, contains('probe-unavailable'));
        }
        await adapter.close();
      }
    },
  );
  for (final interruption in ['close', 'surface', 'display']) {
    test(
      '$interruption during window probe cannot switch a stale candidate',
      () async {
        probeReply = Completer<Map<String, String>>();
        final writes = <int>[];
        final adapter = NativeHdrAdapter(
          write:
              ({
                required token,
                required width,
                required height,
                required transfer,
                required fill,
              }) async {
                writes.add(token);
                return true;
              },
          active: () => true,
          message: (_) {},
          failure: fail,
        );
        await adapter.start();
        final ready = adapter.prepare('pq');
        await Future<void>.delayed(Duration.zero);
        await send(adapter, 'surface', surface());
        Future<void>? closing;
        if (interruption == 'close') {
          closing = adapter.close();
        } else if (interruption == 'surface') {
          await send(adapter, 'surface', surface(token: 0));
        } else {
          await send(adapter, 'changed', {
            'sdk': 34,
            'display': 1,
            'hdrTypes': [2, 3],
            'kind': 'display',
          });
        }
        probeReply!.complete({'status': 'ready'});
        expect(await ready, false);
        expect(writes.where((token) => token != 0), isEmpty);
        await (closing ?? adapter.close());
      },
    );
  }

  test(
    'Surface ready establishes one output; audio notification keeps that output',
    () async {
      final writes = <int>[];
      final messages = <String>[];
      final adapter = NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async {
              writes.add(token);
              return token != 0;
            },
        active: () => true,
        message: messages.add,
        failure: fail,
      );
      await adapter.start();
      final ready = adapter.prepare('pq');
      await Future<void>.delayed(Duration.zero);
      await send(adapter, 'surface', surface());
      expect(await ready, isTrue);
      expect(adapter.established, isTrue);
      expect(writes, [7]);
      await send(adapter, 'changed', {
        'kind': 'audio',
        'sdk': 34,
        'display': 0,
        'hdrTypes': [2, 3],
        'anticipatedAudioTypes': [8],
      });
      expect(writes, [7]);
      expect(adapter.capabilities.audioDescription, contains('蓝牙'));
      expect(messages.last, contains('当前 AO 路由未单独确认'));
      await adapter.close();
      expect(writes.last, 0);
      expect(operations, ['watch', 'probe', 'stop']);
    },
  );
  test(
    'destroyed Surface restores once and never retries from late callbacks',
    () async {
      final writes = <int>[];
      final adapter = NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async {
              writes.add(token);
              return token != 0;
            },
        active: () => true,
        message: (_) {},
        failure: fail,
      );
      await adapter.start();
      final ready = adapter.prepare('hlg');
      await Future<void>.delayed(Duration.zero);
      await send(adapter, 'surface', surface());
      await ready;
      await send(adapter, 'surface', surface(token: 0));
      expect(adapter.established, isFalse);
      expect(adapter.request.value, isNull);
      await send(adapter, 'surface', surface(token: 8));
      expect(await adapter.prepare('hlg'), isFalse);
      expect(writes, [7, 0]);
      await adapter.close();
    },
  );
  test('actual Display change invalidates old HDR eligibility', () async {
    final writes = <int>[];
    final adapter = NativeHdrAdapter(
      write:
          ({
            required token,
            required width,
            required height,
            required transfer,
            required fill,
          }) async {
            writes.add(token);
            return token != 0;
          },
      active: () => true,
      message: (_) {},
      failure: fail,
    );
    await adapter.start();
    final ready = adapter.prepare('pq');
    await Future<void>.delayed(Duration.zero);
    await send(adapter, 'surface', surface());
    await ready;
    await send(adapter, 'changed', {
      'kind': 'display',
      'sdk': 34,
      'display': 1,
      'hdrTypes': [2, 3],
    });
    expect(adapter.established, isFalse);
    expect(writes, [7, 0]);
    await adapter.close();
  });
  test(
    'exit while waiting cancels candidate and unregisters exactly one observer',
    () async {
      final writes = <int>[];
      final adapter = NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async {
              writes.add(token);
              return token != 0;
            },
        active: () => true,
        message: (_) {},
        failure: fail,
      );
      await adapter.start();
      final ready = adapter.prepare('pq');
      await Future<void>.delayed(Duration.zero);
      await adapter.close();
      expect(await ready, isFalse);
      await send(adapter, 'surface', surface());
      expect(writes.where((v) => v != 0), isEmpty);
      expect(operations, ['watch', 'stop']);
    },
  );
  test(
    'destruction during asynchronous attachment cannot publish a stale success',
    () async {
      final attaching = Completer<bool>();
      final entered = Completer<void>();
      final writes = <int>[];
      final adapter = NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async {
              writes.add(token);
              if (token == 0) return false;
              entered.complete();
              return attaching.future;
            },
        active: () => true,
        message: (_) {},
        failure: fail,
      );
      await adapter.start();
      final ready = adapter.prepare('pq');
      await Future<void>.delayed(Duration.zero);
      await send(adapter, 'surface', surface());
      await entered.future;
      await send(adapter, 'surface', surface(token: 0));
      attaching.complete(true);
      expect(await ready, isFalse);
      expect(adapter.established, isFalse);
      expect(writes, [7, 0]);
      await adapter.close();
    },
  );
  test(
    'unavailable native output keeps original view and is not retried',
    () async {
      final writes = <int>[];
      final adapter = NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async {
              writes.add(token);
              return false;
            },
        active: () => true,
        message: (_) {},
        failure: fail,
      );
      await adapter.start();
      final ready = adapter.prepare('pq');
      await Future<void>.delayed(Duration.zero);
      await send(adapter, 'surface', surface());
      expect(await ready, isFalse);
      expect(adapter.request.value, isNull);
      expect(await adapter.prepare('pq'), isFalse);
      expect(writes, [7, 0]);
      await adapter.close();
    },
  );
  test(
    'repeated canceled sessions release every observer and ignore old owners',
    () async {
      final writes = <int>[];
      NativeHdrAdapter? old;
      for (var i = 0; i < 80; i++) {
        final adapter = NativeHdrAdapter(
          write:
              ({
                required token,
                required width,
                required height,
                required transfer,
                required fill,
              }) async {
                writes.add(token);
                return token != 0;
              },
          active: () => true,
          message: (_) {},
          failure: fail,
        );
        await adapter.start();
        if (old != null) await send(old, 'surface', surface());
        final ready = adapter.prepare('pq');
        await Future<void>.delayed(Duration.zero);
        await adapter.close();
        expect(await ready, isFalse);
        old = adapter;
      }
      expect(writes.where((v) => v != 0), isEmpty);
      expect(operations.where((v) => v == 'watch').length, 80);
      expect(operations.where((v) => v == 'stop').length, 80);
    },
  );
  test(
    'replacement Surface restores compatibility instead of attaching over a live token',
    () async {
      final writes = <int>[];
      final adapter = NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async {
              writes.add(token);
              return token != 0;
            },
        active: () => true,
        message: (_) {},
        failure: fail,
      );
      await adapter.start();
      final ready = adapter.prepare('pq');
      await Future<void>.delayed(Duration.zero);
      await send(adapter, 'surface', surface());
      await ready;
      await send(adapter, 'surface', surface(token: 8));
      expect(adapter.established, isFalse);
      expect(writes, [7, 0]);
      await adapter.close();
    },
  );
}
