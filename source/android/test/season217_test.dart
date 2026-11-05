import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/episode_neighbors.dart';
import 'core_test.dart' show syntheticSession, response;
import 'season216_test.dart' show ep, season;

void main() {
  for (final defect in [
    'IsMissing',
    'IsVirtualItem',
    'foreign-series',
    'duplicate-id',
  ]) {
    test(
      'invalid adjacent entry cannot play or authorize skipping a season: $defect',
      () async {
        final calls = <Uri>[];
        final bad = MediaItem({
          ...ep(1, 3).data,
          if (defect == 'IsMissing' || defect == 'IsVirtualItem') defect: true,
          if (defect == 'foreign-series') 'SeriesId': 'another-show',
          if (defect == 'duplicate-id') 'Id': ep(1, 2).id,
        });
        final api = EmbyClient(
          client: MockClient((r) async {
            calls.add(r.url);
            final values = r.url.path.endsWith('/Seasons')
                ? [season(1), season(2)]
                : r.url.queryParameters['SeasonId'] == 's2'
                ? [ep(2, 1)]
                : [ep(1, 1), ep(1, 2), bad];
            return response(
              jsonEncode({
                'Items': values.map((e) => e.data).toList(),
                'TotalRecordCount': values.length,
              }),
              200,
            );
          }),
        )..session = syntheticSession();
        addTearDown(api.close);
        final value = await EpisodeNeighbors.load(api, ep(1, 2));
        expect(value.next, isNull);
        expect(value.warning, isNotNull);
        expect(value.previous?.id, ep(1, 1).id);
        expect(
          calls.length,
          1,
          reason:
              'An invalid next row does not prove this is the season finale',
        );
      },
    );
  }
}
