import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/opening_metadata.dart';
import 'core_test.dart' show syntheticSession;

class DetailApi extends EmbyClient {
  DetailApi(this.read) {
    session = syntheticSession();
  }
  final Future<MediaItem> Function(String) read;
  int calls = 0;
  @override
  Future<MediaItem> detail(String id, {Duration? requestTimeout}) {
    calls++;
    return read(id);
  }
}

MediaItem item(String id) => MediaItem({
  'Id': id,
  'Type': 'Episode',
  'SeriesId': 'series',
  'MediaSources': [
    {
      'Id': 'source',
      'MediaStreams': [
        {'Type': 'Video', 'DoviProfile': 8, 'Codec': 'hevc'},
      ],
    },
  ],
  'UserData': {'PlaybackPositionTicks': 1234000000},
});

void main() {
  test(
    'one fresh request retains exact metadata including Dolby and resume',
    () async {
      final source = item('one');
      final api = DetailApi((_) async => source);
      addTearDown(api.close);
      final pending = OpeningMetadata.begin(api, 'one');
      expect(await pending.take(api, 'one'), same(source));
      expect(api.calls, 1);
      await expectLater(pending.take(api, 'one'), throwsA(isA<AppFailure>()));
      pending.cancel();
    },
  );
  for (final invalid in ['target', 'client', 'account', 'cancel']) {
    test('opening metadata refuses a changed $invalid', () async {
      final gate = Completer<MediaItem>();
      final api = DetailApi((_) => gate.future);
      final other = DetailApi((id) async => item(id));
      addTearDown(api.close);
      addTearDown(other.close);
      final pending = OpeningMetadata.begin(api, 'one');
      if (invalid == 'account') api.session = syntheticSession();
      if (invalid == 'cancel') pending.cancel();
      gate.complete(item('one'));
      await expectLater(
        pending.take(
          invalid == 'client' ? other : api,
          invalid == 'target' ? 'two' : 'one',
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(api.calls, 1);
      expect(other.calls, 0);
    });
  }
  test(
    'late cancel or account switch while HTTP is pending refuses its result',
    () async {
      for (final cancel in [true, false]) {
        final gate = Completer<MediaItem>();
        final api = DetailApi((_) => gate.future);
        addTearDown(api.close);
        final pending = OpeningMetadata.begin(api, 'one');
        final take = pending.take(api, 'one');
        if (cancel) {
          pending.cancel();
        } else {
          api.session = syntheticSession();
        }
        gate.complete(item('one'));
        await expectLater(take, throwsA(isA<AppFailure>()));
      }
    },
  );
  test('response resource identity is verified before routing', () async {
    final api = DetailApi((_) async => item('wrong'));
    addTearDown(api.close);
    final pending = OpeningMetadata.begin(api, 'one');
    await expectLater(pending.take(api, 'one'), throwsA(isA<AppFailure>()));
  });
  test(
    'unused failures stay handled; consumed failure remains visible without retry',
    () async {
      final api = DetailApi(
        (_) async => throw const AppFailure('synthetic detail failure'),
      );
      addTearDown(api.close);
      final discarded = OpeningMetadata.begin(api, 'unused')..cancel();
      final pending = OpeningMetadata.begin(api, 'one');
      await Future<void>.delayed(Duration.zero);
      await expectLater(pending.take(api, 'one'), throwsA(isA<AppFailure>()));
      discarded.cancel();
      expect(api.calls, 2);
    },
  );
  test(
    'aged ready metadata refreshes once, a slow newly arrived response does not',
    () async {
      final gate = Completer<MediaItem>();
      final ready = DetailApi((id) async => item(id));
      final slow = DetailApi((_) => gate.future);
      addTearDown(ready.close);
      addTearDown(slow.close);
      final aged = OpeningMetadata.begin(ready, 'one');
      final arriving = OpeningMetadata.begin(slow, 'two');
      await Future<void>.delayed(const Duration(milliseconds: 5250));
      await aged.take(ready, 'one');
      expect(aged.refreshed, isTrue);
      expect(ready.calls, 2);
      gate.complete(item('two'));
      await arriving.take(slow, 'two');
      expect(arriving.refreshed, isFalse);
      expect(slow.calls, 1);
    },
  );
  test(
    '200 alternating accepted and cancelled intents never share results or start media',
    () async {
      final api = DetailApi((id) async => item(id));
      addTearDown(api.close);
      for (var i = 0; i < 200; i++) {
        final id = 'synthetic-$i';
        final p = OpeningMetadata.begin(api, id);
        if (i.isEven) {
          p.cancel();
        } else {
          expect((await p.take(api, id)).id, id);
        }
      }
      await Future<void>.delayed(Duration.zero);
      expect(api.calls, 200);
    },
  );
}
