import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';

const _first = '11111111111111111111111111111111';
const _second = '22222222222222222222222222222222';

Map<String, Object> _title(int playlist, String clip, {bool main = false}) => {
  'playlist': playlist,
  'main': main,
  'duration': 900000,
  'clips': [
    {'id': clip, 'in': 54000000, 'out': 54900000},
  ],
  'chapters': [0, 450000],
};

String _index(String clip, {int packetCount = 10000}) => jsonEncode([
  {
    'clip': clip,
    'pid': 4113,
    'packetCount': packetCount,
    'points': [
      [54000000, 1],
      [54900000, 500],
    ],
  },
]);

class _NoNetwork extends HttpOverrides {
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('This integration test must never create an HTTP client');
  }
}

typedef _Invoke = Future<Object?> Function(String, Map<String, Object?>);

DiscTransport _transport(String id, _Invoke invoke) => DiscTransport(
  PlaybackRoute(
    url: 'https://synthetic.invalid/entry.iso?token=SYNTHETIC',
    sourceId: 'synthetic-source',
    sessionId: 'synthetic-play',
    headers: const {'User-Agent': 'Synthetic/1'},
    streams: const [],
    discKind: DiscKind.iso,
  ),
  kind: DiscKind.iso,
  directInput: true,
  sessionId: id,
  nativeInvoke: invoke,
);

Future<void> _withoutNetwork(Future<void> Function() body) async {
  final overrides = _NoNetwork();
  await HttpOverrides.runWithHttpOverrides(body, overrides);
  expect(overrides.attempts, 0);
}

void main() {
  test(
    'native transport publishes only explicitly selected CLPI and original EDL',
    () async {
      await _withoutNetwork(() async {
        final calls = <String>[];
        final data = [_title(1, '00001', main: true), _title(2, '00002')];
        final transport = _transport(_first, (method, arguments) async {
          calls.add(method);
          expect(arguments['id'], _first);
          switch (method) {
            case 'open':
              expect(arguments['base'], 'yingyu-disc://$_first');
              expect(arguments['iso'], isTrue);
              return jsonEncode(data);
            case 'select':
              expect(arguments['clips'], ['00002']);
              return null;
            case 'selectIndex':
              expect(arguments['playlist'], 2);
              return _index('00002');
            case 'close':
              return null;
            default:
              fail('Unexpected native operation: $method');
          }
        });
        try {
          final edl = await transport.start(playlist: 2);
          expect(edl, DiscTitle(data[1]).edl('yingyu-disc://$_first'));
          expect(
            transport.seekIndex,
            'YI1|$_first|00002,4113,10000,54000000:1,54900000:500',
          );
          expect(transport.selected!.playlist, 2);
          expect(transport.titles, hasLength(2));
          expect(transport.failure, isNull);
          expect(calls, ['open', 'select', 'selectIndex']);
        } finally {
          await transport.close();
        }
        expect(calls.last, 'close');
      });
    },
  );

  final invalid = <String, Future<Object?> Function()>{
    'absent optional result': () async => null,
    'empty optional index': () async => '[]',
    'malformed JSON': () async => '{bad',
    'foreign clip': () async => _index('99999'),
    'out of bounds packet': () async => _index('00001', packetCount: 500),
    'native optional operation unavailable': () async =>
        throw MissingPluginException('Synthetic optional operation'),
    'native optional operation failed': () async =>
        throw PlatformException(code: 'synthetic-index-unavailable'),
  };
  for (final entry in invalid.entries) {
    test(
      '${entry.key} retains original EDL, chapter metadata and main title',
      () async {
        await _withoutNetwork(() async {
          final data = _title(1, '00001', main: true);
          final calls = <String>[];
          final transport = _transport(_first, (method, arguments) async {
            calls.add(method);
            switch (method) {
              case 'open':
                return jsonEncode([data]);
              case 'selectIndex':
                return entry.value();
              default:
                return null;
            }
          });
          try {
            expect(
              await transport.start(),
              DiscTitle(data).edl('yingyu-disc://$_first'),
            );
            expect(transport.seekIndex, isEmpty);
            expect(transport.selected!.playlist, 1);
            expect(transport.selected!.chapters, [0, 450000]);
            expect(transport.failure, isNull);
            expect(calls, ['open', 'select', 'selectIndex']);
          } finally {
            await transport.close();
          }
        });
      },
    );
  }

  test(
    'closing during index wait rejects start and late reply cannot publish index',
    () async {
      await _withoutNetwork(() async {
        final entered = Completer<void>();
        final reply = Completer<Object?>();
        var closes = 0;
        final transport = _transport(_first, (method, arguments) async {
          switch (method) {
            case 'open':
              return jsonEncode([_title(1, '00001')]);
            case 'selectIndex':
              entered.complete();
              return reply.future;
            case 'close':
              closes++;
              return null;
            default:
              return null;
          }
        });
        final opening = transport.start();
        final failedStart = expectLater(opening, throwsA(isA<AppFailure>()));
        await entered.future;
        await transport.close();
        expect(closes, 1);
        reply.complete(_index('00001'));
        await failedStart;
        expect(transport.seekIndex, isEmpty);
        await transport.close();
        expect(closes, 1);
      });
    },
  );

  test(
    'native cancellation while indexing settles start without fabricating EDL',
    () async {
      await _withoutNetwork(() async {
        final entered = Completer<void>();
        final reply = Completer<Object?>();
        final transport = _transport(_first, (method, arguments) async {
          switch (method) {
            case 'open':
              return jsonEncode([_title(1, '00001')]);
            case 'selectIndex':
              entered.complete();
              return reply.future;
            case 'close':
              // Match DiscNativeSession.close completing the pending control RPC.
              reply.completeError(const AppFailure('播放已退出'));
              return null;
            default:
              return null;
          }
        });
        final opening = transport.start();
        final failedStart = expectLater(opening, throwsA(isA<AppFailure>()));
        await entered.future;
        await transport.close();
        await failedStart;
        expect(transport.seekIndex, isEmpty);
      });
    },
  );

  test(
    'closed old session reply cannot replace a newer session index',
    () async {
      await _withoutNetwork(() async {
        final entered = Completer<void>();
        final oldReply = Completer<Object?>();
        final calls = <String>[];
        Future<Object?> invoke(
          String method,
          Map<String, Object?> arguments,
        ) async {
          final id = arguments['id'];
          calls.add('$id:$method');
          switch (method) {
            case 'open':
              return jsonEncode([_title(1, '00001')]);
            case 'selectIndex':
              if (id == _first) {
                entered.complete();
                return oldReply.future;
              }
              return _index('00001', packetCount: 20000);
            default:
              return null;
          }
        }

        final old = _transport(_first, invoke);
        final current = _transport(_second, invoke);
        final oldOpening = old.start();
        final oldFailure = expectLater(oldOpening, throwsA(isA<AppFailure>()));
        await entered.future;
        await old.close();
        try {
          final edl = await current.start();
          expect(edl, contains('yingyu-disc://$_second/clip/00001.m2ts'));
          final currentIndex = current.seekIndex;
          expect(
            currentIndex,
            'YI1|$_second|00001,4113,20000,54000000:1,54900000:500',
          );
          oldReply.complete(_index('00001'));
          await oldFailure;
          expect(old.seekIndex, isEmpty);
          expect(current.seekIndex, currentIndex);
          expect(calls.where((c) => c == '$_first:selectIndex'), hasLength(1));
          expect(calls.where((c) => c == '$_second:selectIndex'), hasLength(1));
        } finally {
          await current.close();
        }
      });
    },
  );
}
