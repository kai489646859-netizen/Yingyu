import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_stream.dart';

void main() {
  test(
    'an interrupted external body resumes exact bytes once after closing the old response',
    () async {
      final events = <String>[];
      final bytes = Uint8List.fromList(List.generate(1024, (i) => i % 251));
      final reader = DiscStreamReader((path, start, cancel) async {
        events.add('open:$start');
        return DiscStreamSource(
          start: start,
          total: bytes.length,
          canResume: true,
          validator: 'same',
          bytes: () async* {
            if (start == 0) {
              yield bytes.sublist(0, 103);
              throw const HttpException(
                'Connection closed while receiving data',
              );
            }
            yield bytes.sublist(start);
          }(),
          close: (_) => events.add('close:$start'),
        );
      });
      final first = await reader.read('', 0, 300, DiscReadCancellation());
      final rest = await reader.read('', 300, 724, DiscReadCancellation());
      expect([...first.bytes, ...rest.bytes], bytes);
      expect(events, ['open:0', 'close:0', 'open:103', 'close:103']);
      expect(reader.resumedResponses, 1);
      await reader.close();
    },
  );
  for (final mode in ['same-origin', 'twice', 'changed', 'rejected']) {
    test(
      'body recovery stops for $mode and never retries subsequent reads',
      () async {
        var opens = 0;
        final reader = DiscStreamReader((path, start, cancel) async {
          opens++;
          if (opens > 1 && mode == 'rejected') {
            throw const AppFailure('HTTP 403');
          }
          return DiscStreamSource(
            start: start,
            total: 1024,
            canResume: mode != 'same-origin',
            validator: opens > 1 && mode == 'changed' ? 'changed' : 'same',
            bytes: () async* {
              yield [1, 2];
              throw const SocketException('synthetic disconnect');
            }(),
            close: (_) {},
          );
        });
        for (var i = 0; i < 3; i++) {
          await expectLater(
            reader.read('', 0, 16, DiscReadCancellation()),
            throwsA(anything),
          );
        }
        expect(opens, mode == 'same-origin' ? 1 : 2);
        await reader.close();
      },
    );
  }
  test(
    'cancellation during a recoverable stream never opens a replacement',
    () async {
      var opens = 0;
      final body = StreamController<List<int>>();
      final ready = Completer<void>();
      final reader = DiscStreamReader((path, start, cancel) async {
        opens++;
        ready.complete();
        return DiscStreamSource(
          start: start,
          total: 1024,
          canResume: true,
          bytes: body.stream,
          close: (_) {},
        );
      });
      final cancel = DiscReadCancellation();
      final failed = expectLater(
        reader.read('', 0, 16, cancel),
        throwsA(anything),
      );
      await ready.future;
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      await failed;
      expect(opens, 1);
      await reader.close();
      await body.close();
    },
  );
}
