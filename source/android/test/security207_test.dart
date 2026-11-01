import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';

class MetadataClient207 extends http.BaseClient {
  MetadataClient207(this.body, {this.length});
  Stream<List<int>> body;
  int? length;
  bool aborted = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.AbortableRequest) {
      unawaited(
        request.abortTrigger!.then((_) {
          aborted = true;
        }),
      );
    }
    return http.StreamedResponse(body, 200, contentLength: length);
  }
}

void main() {
  test(
    'oversize cleanup failure cannot replace the rejection or escape as an async error',
    () async {
      final stream = StreamController<List<int>>(
        onCancel: () =>
            Future<void>.error(StateError('synthetic cancellation failure')),
      );
      final client = EmbyClient(
        client: MetadataClient207(stream.stream, length: 65 * 1024 * 1024),
      );
      addTearDown(client.close);
      await expectLater(
        client.request(
          Uri.parse('https://synthetic.invalid/Items'),
          headers: {},
        ),
        throwsA(
          isA<AppFailure>().having((e) => e.message, 'message', contains('过大')),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    },
  );
  test(
    'rejected metadata does not poison a following normal request',
    () async {
      final transport = MetadataClient207(
        Stream.value(utf8.encode('{}')),
        length: 65 * 1024 * 1024,
      );
      final client = EmbyClient(client: transport);
      addTearDown(client.close);
      await expectLater(
        client.request(
          Uri.parse('https://synthetic.invalid/Items'),
          headers: {},
        ),
        throwsA(isA<AppFailure>()),
      );
      transport.length = null;
      transport.body = Stream.value(
        utf8.encode('{"Items":[{"Id":"synthetic"}],"TotalRecordCount":1}'),
      );
      final result = await client.request(
        Uri.parse('https://synthetic.invalid/Items'),
        headers: {},
      );
      expect(result['TotalRecordCount'], 1);
    },
  );
  test('compressed metadata is bounded after decompression', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = EmbyClient();
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    final done = Completer<void>();
    server.listen((request) async {
      request.response.headers.set('content-encoding', 'gzip');
      final space = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 32);
      Stream<List<int>> body() async* {
        yield utf8.encode('{}');
        for (var i = 0; i < 65; i++) {
          yield space;
        }
      }

      try {
        await request.response.addStream(body().transform(gzip.encoder));
        await request.response.close();
      } catch (_) {
      } finally {
        done.complete();
      }
    });
    await expectLater(
      client.request(
        Uri.parse('http://127.0.0.1:${server.port}/Items'),
        headers: {},
      ),
      throwsA(
        isA<AppFailure>().having((e) => e.message, 'message', contains('过大')),
      ),
    );
    await done.future;
  });
  test(
    'exact byte limit is accepted without truncating valid metadata',
    () async {
      final space = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 32);
      Stream<List<int>> body() async* {
        yield utf8.encode('{}');
        for (var i = 0; i < 63; i++) {
          yield space;
        }
        yield Uint8List.sublistView(space, 2);
      }

      final client = EmbyClient(
        client: MetadataClient207(body(), length: 64 * 1024 * 1024),
      );
      addTearDown(client.close);
      expect(
        await client.request(
          Uri.parse('https://synthetic.invalid/Items'),
          headers: {},
        ),
        isEmpty,
      );
    },
  );
  test(
    'oversized declared successful metadata is rejected before buffering',
    () async {
      var read = false;
      Stream<List<int>> body() async* {
        read = true;
        yield utf8.encode('{}');
      }

      final transport = MetadataClient207(body(), length: 65 * 1024 * 1024);
      final client = EmbyClient(client: transport);
      addTearDown(client.close);
      await expectLater(
        client.request(
          Uri.parse('https://synthetic.invalid/Items'),
          headers: {},
        ),
        throwsA(
          isA<AppFailure>().having((e) => e.message, 'message', contains('过大')),
        ),
      );
      expect(read, false);
      await Future<void>.delayed(Duration.zero);
      expect(transport.aborted, true);
    },
  );
  test(
    'unknown-length metadata stops at its byte budget and cancels the stream',
    () async {
      var produced = 0, cancelled = false;
      final space = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 32);
      Stream<List<int>> body() async* {
        try {
          yield utf8.encode('{}');
          for (var i = 0; i < 96; i++) {
            produced++;
            yield space;
          }
        } finally {
          cancelled = true;
        }
      }

      final transport = MetadataClient207(body());
      final client = EmbyClient(client: transport);
      addTearDown(client.close);
      await expectLater(
        client.request(
          Uri.parse('https://synthetic.invalid/Items'),
          headers: {},
        ),
        throwsA(
          isA<AppFailure>().having((e) => e.message, 'message', contains('过大')),
        ),
      );
      expect(produced, lessThanOrEqualTo(64));
      expect(cancelled, true);
      await Future<void>.delayed(Duration.zero);
      expect(transport.aborted, true);
    },
  );
}
