import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'playback_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'isolated startup comparison with a delayed metadata API and no media access',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      var detailCalls = 0, infoCalls = 0;
      final backend = FakeBackend()..gate.complete();
      final api = EmbyClient(
        client: MockClient((req) async {
          if (req.url.path.endsWith('/PlaybackInfo')) {
            infoCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 600));
            return response(jsonEncode(playbackData()), 200);
          }
          if (req.url.path.contains('/Sessions/Playing')) {
            return response('', 204);
          }
          detailCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return response(
            jsonEncode({
              'Id': 'movie',
              'Type': 'Movie',
              'Name': 'SYNTHETIC',
              'MediaSources': [
                {
                  'Id': 'source-1',
                  'Type': 'Default',
                  'Protocol': 'Http',
                  'Path': 'https://synthetic.invalid/item.mkv?old=expired',
                  'Container': 'strm',
                  'DirectStreamUrl':
                      '/emby/Videos/movie/stream?Static=true&MediaSourceId=source-1',
                  'SupportsDirectStream': true,
                  'RequiresOpening': false,
                  'RequiredHttpHeaders': <String, String>{},
                  'MediaStreams': <Object>[],
                },
              ],
              'UserData': {'PlaybackPositionTicks': 12340000000},
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
      final watch = Stopwatch()..start();
      await session.open();
      watch.stop();
      expect(session.ready, true);
      expect(backend.initial, const Duration(seconds: 1234));
      final target = Platform.environment['YINGYU_STARTUP_BENCHMARK'];
      if (target != null) {
        File(target).writeAsStringSync(
          jsonEncode({
            'elapsed_ms': watch.elapsedMilliseconds,
            'fresh_detail_requests': detailCalls,
            'playback_info_requests': infoCalls,
            'simulated_info_delay_ms': 600,
            'backend_initial_ms': backend.initial!.inMilliseconds,
            'backend_ready': session.ready,
            'native_playback': false,
            'real_media_requests': 0,
          }),
        );
      }
      await session.close();
      session.dispose();
      api.close();
      store.dispose();
    },
  );
}
