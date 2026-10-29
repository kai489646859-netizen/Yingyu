import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/native_hdr.dart';
import 'host/hdr102_old_native_hdr.dart' as old;
import 'hdr_recovery101_test.dart' show RealOutputFixture;

class PictureLease extends StatefulWidget {
  const PictureLease(this.created, this.released, {super.key});
  final VoidCallback created, released;
  @override
  State<PictureLease> createState() => _PictureLeaseState();
}

class _PictureLeaseState extends State<PictureLease> {
  @override
  void initState() {
    super.initState();
    widget.created();
  }

  @override
  void dispose() {
    widget.released();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.blue);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yingyu/native_hdr');
  const codec = StandardMethodCodec();
  final calls = <String>[];
  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'probe') return {'status': 'ready'};
      return call.method == 'watch'
          ? {
              'sdk': 37,
              'display': 0,
              'hdrTypes': [2, 3],
            }
          : null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        if (call.method == 'resize') return {'width': 800.0, 'height': 600.0};
        return null;
      },
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      null,
    );
    debugDefaultTargetPlatformOverride = null;
  });
  Future<void> surface(dynamic adapter) async {
    final reply = Completer<void>();
    // An Android callback seam, not a native Surface or physical video.
    // ignore: deprecated_member_use
    binding.defaultBinaryMessenger.handlePlatformMessage(
      'yingyu/native_hdr',
      codec.encodeMethodCall(
        MethodCall('surface', {
          'owner': adapter.owner,
          'token': 7,
          'width': 1920,
          'height': 1080,
          'sdk': 37,
          'display': 0,
          'hdrTypes': [2, 3],
        }),
      ),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  testWidgets(
    'HDR candidate preserves the existing picture state across admission',
    (tester) async {
      var created = 0, released = 0;
      final adapter = NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async => token != 0,
        active: () => true,
        message: (_) {},
        failure: fail,
      );
      await adapter.start();
      await tester.pumpWidget(
        MaterialApp(
          home: adapter.view(
            PictureLease(() => created++, () => released++),
            BoxFit.contain,
            subtitles: const SizedBox(),
          ),
        ),
      );
      final before = tester.state(
        find.byType(PictureLease, skipOffstage: false),
      );
      final ready = adapter.prepare('pq');
      await tester.pump();
      final preserved = identical(
        tester.state(find.byType(PictureLease, skipOffstage: false)),
        before,
      );
      await surface(adapter);
      await ready;
      await adapter.close();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      expect(
        preserved,
        true,
        reason:
            'creating the optional HDR view must not dispose/recreate the healthy picture owner',
      );
      expect(created, 1);
      expect(released, 1);
    },
  );
  test(
    'failed restoration still clears the HDR view request before close completes',
    () async {
      var closing = false;
      final adapter = NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async {
              if (closing) throw StateError('output already failed');
              return token != 0;
            },
        active: () => true,
        message: (_) {},
        failure: fail,
      );
      await adapter.start();
      final ready = adapter.prepare('pq');
      await Future<void>.delayed(Duration.zero);
      await surface(adapter);
      expect(await ready, true);
      closing = true;
      await expectLater(adapter.close(), throwsStateError);
      expect(calls.last, 'stop');
      expect(
        adapter.request.value,
        isNull,
        reason:
            'a failed renderer cannot leave the native HDR layer requested after exit',
      );
      expect(adapter.established, false);
    },
  );
  test(
    'released101 complete adapter retains the rejected HDR request',
    () async {
      var closing = false;
      final adapter = old.NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async {
              if (closing) throw StateError('output already failed');
              return token != 0;
            },
        active: () => true,
        message: (_) {},
        failure: fail,
      );
      await adapter.start();
      final ready = adapter.prepare('pq');
      await Future<void>.delayed(Duration.zero);
      await surface(adapter);
      expect(await ready, true);
      closing = true;
      await expectLater(adapter.close(), throwsStateError);
      expect(
        adapter.request.value,
        'pq',
        reason:
            'same observed close pattern remains a baseline behavior failure',
      );
      expect(adapter.established, true);
    },
  );
  for (final brokenFrame in [false, true]) {
    test(
      'closing HDR detaches output without recreating a frame; broken=$brokenFrame',
      () async {
        final f = RealOutputFixture()..hdrAvailable = true;
        expect(await f.apply(), true);
        f.noRestoredFrame = brokenFrame;
        f.rejected = true;
        f.writes.clear();
        await f.output.detachForClose(read: f.read, write: f.write);
        expect(f.writes, [('vo', 'null'), ('wid', '0')]);
        expect(f.output.active, false);
        expect(f.output.token, 0);
        expect(f.output.status, 'closed-detached');
        f.writes.clear();
        await f.output.detachForClose(read: f.read, write: f.write);
        expect(f.writes, isEmpty);
      },
    );
  }
  for (final status in [
    'dataspace-library',
    'dataspace-symbols',
    'dataspace-set',
    'dataspace-readback',
    'buffer-format',
  ]) {
    test('native $status rejects before any live output write', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'watch') {
          return {
            'sdk': 37,
            'display': 0,
            'hdrTypes': [2],
          };
        }
        if (call.method == 'probe') return {'status': status};
        return null;
      });
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
        detach: () async {},
        active: () => true,
        message: (_) {},
        failure: fail,
      );
      await adapter.start();
      final ready = adapter.prepare('pq');
      await Future<void>.delayed(Duration.zero);
      await surface(adapter);
      expect(await ready, false);
      expect(writes, isEmpty);
      expect(adapter.request.value, isNull);
      expect(adapter.status, 'window-$status');
      await adapter.close();
      expect(writes, isEmpty);
    });
  }
  test(
    'closing uses detach once, never a compatibility write or frame wait',
    () async {
      var releases = 0;
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
        detach: () async {
          releases++;
        },
        active: () => true,
        message: (_) {},
        failure: fail,
      );
      await adapter.start();
      final ready = adapter.prepare('pq');
      await Future<void>.delayed(Duration.zero);
      await surface(adapter);
      expect(await ready, true);
      final first = adapter.close(), second = adapter.close();
      expect(identical(first, second), true);
      await first;
      expect(releases, 1);
      expect(writes, [7]);
      expect(adapter.request.value, isNull);
      expect(calls.where((m) => m == 'stop').length, 1);
    },
  );
}
