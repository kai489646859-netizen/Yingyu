import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'package:yingyu/ui/people.dart';

void main() {
  test(
    'an available Emby person image tag is not lost to an empty optional image map',
    () {
      expect(
        personImage({
          'Id': 'actor',
          'ImageTags': {'Primary': ''},
          'PrimaryImageTag': 'real-tag',
        }).imageTag,
        'real-tag',
      );
      expect(personImage({'Id': 'no-image'}).imageTag, isEmpty);
    },
  );
  test(
    'visible actors precede queued posters without exceeding two bodies',
    () async {
      final starts = <String>[], gates = <Completer<void>>[];
      var active = 0, peak = 0;
      final service = PosterFileService(
        spacing: Duration.zero,
        requestLimit: 0,
        visible: (_) => true,
        priority: (url) => url.endsWith('actor'),
        client: MockClient((r) async {
          starts.add(r.url.path);
          active++;
          if (active > peak) peak = active;
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          active--;
          return http.Response('image', 200);
        }),
      );
      final jobs = [
        for (final name in ['first', 'second', 'poster', 'actor'])
          service.get('https://fixture.invalid/$name'),
      ];
      while (starts.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      gates[0].complete();
      await jobs[0];
      while (starts.length < 3) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(starts[2], '/actor');
      expect(peak, 2);
      gates[1].complete();
      while (starts.length < 4) {
        await Future<void>.delayed(Duration.zero);
      }
      gates[2].complete();
      gates[3].complete();
      await Future.wait(jobs);
      expect(peak, 2);
    },
  );
  test(
    'actor diagnostics contain queue facts, not addresses, names or tokens',
    () async {
      var clock = DateTime.utc(2026);
      final rows = <String>[];
      final service = PosterFileService(
        spacing: const Duration(seconds: 3),
        requestLimit: 0,
        priority: (_) => true,
        visible: (_) => true,
        now: () => clock,
        delay: (d) async => clock = clock.add(d),
        client: MockClient((r) async => http.Response('image', 200)),
      )..diagnostic = rows.add;
      await service.get('https://private.invalid/first?api_key=SECRET');
      await service.get('https://private.invalid/second?api_key=SECRET');
      expect(rows.single, contains('排队'));
      expect(rows.single, contains('3000'));
      expect(rows.single, isNot(contains('private')));
      expect(rows.single, isNot(contains('SECRET')));
    },
  );
}
