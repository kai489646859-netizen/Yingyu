import 'package:flutter_test/flutter_test.dart';
import 'host/release100/current_tracks.dart' as current;
import 'host/release100/old_tracks.dart' as old;

class TrackIo {
  final values = <String, String>{
    'track-list/count': '8',
    'aid': '1',
    'sid': '4',
  };
  final reads = <String>[];
  int pending = 0, maxPending = 0;
  bool failingOptional = false;
  TrackIo() {
    for (var i = 0; i < 8; i++) {
      final prefix = 'track-list/$i/';
      values.addAll({
        '${prefix}type': i == 0
            ? 'video'
            : i < 3
            ? 'audio'
            : 'sub',
        '${prefix}id': '$i',
        '${prefix}src-id': '${100 + i}',
        '${prefix}ff-index': '$i',
        '${prefix}forced': i == 7 ? 'yes' : 'no',
        '${prefix}external': i == 6 ? 'yes' : 'no',
      });
    }
  }
  Future<String> read(String key) async {
    reads.add(key);
    pending++;
    if (pending > maxPending) maxPending = pending;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      if (failingOptional && key.endsWith('/src-id')) {
        throw StateError('optional unavailable');
      }
      return values[key] ?? '';
    } finally {
      pending--;
    }
  }
}

void main() {
  testWidgets(
    'initial subtitle metadata is ready within one bounded reply batch',
    (tester) async {
      final io = TrackIo();
      final dynamic h = const bool.fromEnvironment('YINGYU_BASELINE100')
          ? old.TrackHarness(io.read)
          : current.TrackHarness(io.read);
      var complete = false;
      final future = (h.refresh() as Future<void>).then((_) {
        complete = true;
      });
      await tester.pump(const Duration(milliseconds: 300));
      final observed = complete;
      await tester.pump(const Duration(seconds: 3));
      await future;
      expect(
        observed,
        true,
        reason:
            'Serial property round trips delay HDR even after its initial frame',
      );
      expect(h.metadata.length, 7);
      expect(h.selectedAudioId, '1');
      expect(h.selectedSubtitleId, '4');
      expect(io.maxPending, lessThanOrEqualTo(20));
    },
  );
  testWidgets(
    'old and current complete methods return identical track and selection facts',
    (tester) async {
      final before = TrackIo()..failingOptional = true;
      final after = TrackIo()..failingOptional = true;
      final a = old.TrackHarness(before.read),
          b = current.TrackHarness(after.read);
      final future = Future.wait([a.refresh(), b.refresh()]);
      await tester.pump(const Duration(seconds: 3));
      await future;
      expect(b.metadata, a.metadata);
      expect(b.selectedAudioId, a.selectedAudioId);
      expect(b.selectedSubtitleId, a.selectedSubtitleId);
      expect(b.metadata['sub:7']?.forced, true);
      expect(b.metadata['sub:6']?.external, true);
      expect(b.metadata['audio:1']?.pid, isNull);
    },
  );
  testWidgets('retired track refresh cannot publish late facts', (
    tester,
  ) async {
    final io = TrackIo();
    final h = current.TrackHarness(io.read);
    final future = h.refresh();
    await tester.pump(const Duration(milliseconds: 30));
    h.dispose();
    await tester.pump(const Duration(seconds: 1));
    await future;
    expect(h.metadata, isEmpty);
    expect(h.emissions, 0);
    expect(io.pending, 0);
  });
}
