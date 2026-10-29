import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:yingyu/playback/diagnostics.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'host/disc_open/current.dart' as current;
import 'host/disc_open/previous.dart' as previous;

const _id = '0123456789abcdef0123456789abcdef';
const _extras = {'yingyuNativeDiscSession': _id};
final _title = DiscTitle({
  'playlist': 1,
  'duration': 8100000,
  'clips': [
    {'id': '00001', 'in': 900000, 'out': 6300000},
    {'id': '00002', 'in': 180000, 'out': 2880000},
  ],
});

void main() {
  test('delivered 0.6.8 wraps native EDL in a filesystem loadlist', () async {
    final player = previous.ReplayPlayer();
    addTearDown(player.close);
    final media = Media(_title.edl('yingyu-disc://$_id'), extras: _extras);
    await player.open(media, play: false);
    expect(player.load.first, 'loadlist');
    expect(player.target, media.uri);
  });

  test(
    'generated native timeline loads directly with start and paused state',
    () async {
      final player = current.ReplayPlayer();
      addTearDown(player.close);
      final media = Media(
        _title.edl('yingyu-disc://$_id'),
        extras: _extras,
        httpHeaders: const {},
        start: const Duration(milliseconds: 1095541),
      );
      await player.open(media, play: false);
      expect(player.load, ['loadfile', media.uri, 'append']);
      expect(player.properties, {'pause': true, 'playlist-pos': 0});
      expect(player.current.single, same(media));
      expect(
        player.current.single.start,
        const Duration(milliseconds: 1095541),
      );
      expect(player.current.single.httpHeaders, isEmpty);
      expect(player.target, contains(',10.000000,60.000000;'));
      expect(
        player.commands.any((c) => c.contains('load-unsafe-playlists')),
        false,
      );
    },
  );

  test(
    'ordinary signed URLs and persistent-cache EDL retain loadlist',
    () async {
      for (final uri in [
        'https://synthetic.invalid/file?sign=%2f%2B&x=a+b&x=2',
        _title.edl('http://127.0.0.1:3456/session'),
      ]) {
        final player = current.ReplayPlayer();
        addTearDown(player.close);
        final media = Media(uri, extras: const {});
        await player.open(media);
        expect(player.load.first, 'loadlist');
        expect(player.target, uri);
        expect(player.properties['pause'], false);
        expect(player.state.playing, true);
      }
    },
  );

  test(
    'unmarked or mismatched native timelines do not gain direct opening',
    () async {
      for (final extras in <Map<String, dynamic>>[
        {},
        {'yingyuNativeDiscSession': 'f' * 32},
        {'yingyuNativeDiscSession': true},
        {'yingyuNativeDiscSession': '../arbitrary'},
      ]) {
        final player = current.ReplayPlayer();
        addTearDown(player.close);
        await player.open(
          Media(_title.edl('yingyu-disc://$_id'), extras: extras),
        );
        expect(player.load.first, 'loadlist');
      }
    },
  );

  test(
    'marked remote file, mixed URLs, extra headers or invalid cuts stay restricted',
    () async {
      final good = _title.edl('yingyu-disc://$_id');
      for (final uri in [
        'https://synthetic.invalid/playlist.m3u',
        'file:///synthetic-private-file',
        good.replaceFirst('%62%', '%61%'),
        '$good;file:///synthetic-private-file,0,1',
        '$good;!new_stream',
        good.replaceFirst('00001.m2ts', '../bad.m2ts'),
        good.replaceFirst('60.000000', '0.000000'),
        good.replaceFirst('60.000000', 'NaN'),
        good.replaceFirst('60.000000', 'Infinity'),
        'edl://!no_chapters;',
        '$good\n',
        'edl://!no_chapters;${List.filled(4097, good.split(';')[1]).join(';')}',
      ]) {
        final player = current.ReplayPlayer();
        addTearDown(player.close);
        await player.open(Media(uri, extras: _extras));
        expect(player.load.first, 'loadlist', reason: uri);
      }
    },
  );

  test('fd direct route and ordinary playlist order remain intact', () async {
    final fd = current.ReplayPlayer(), list = current.ReplayPlayer();
    addTearDown(fd.close);
    addTearDown(list.close);
    await fd.open(Media('fd://42'));
    expect(fd.load.first, 'loadfile');
    final medias = [
      Media('https://synthetic.invalid/1'),
      Media('https://synthetic.invalid/2'),
    ];
    await list.open(Playlist(medias, index: 1), play: false);
    expect(list.load.first, 'loadlist');
    expect(list.target.split('\n'), medias.map((m) => m.uri));
    expect(list.properties['playlist-pos'], 1);
  });

  test('native marker cannot promote a mixed playlist', () async {
    final player = current.ReplayPlayer();
    addTearDown(player.close);
    await player.open(
      Playlist([
        Media(_title.edl('yingyu-disc://$_id'), extras: _extras),
        Media('https://synthetic.invalid/other'),
      ]),
    );
    expect(player.load.first, 'loadlist');
  });

  test('blank MPV prelude does not consume the actual failure reason', () {
    final failures = [
      '\n',
      'Refusing to load potentially unsafe URL from a playlist.\n',
      'Use the --load-unsafe-playlists option to load it anyway.\n',
      '\n',
    ].where((text) => isMpvErrorLog('stream', 'error', text));
    expect(mpvOpenFailure('stream', failures.first), contains('入口类型不兼容'));
    expect(isMpvErrorLog('cplayer', 'error', ' \r\n'), false);
  });

  test(
    'protocol diagnostic drops URI secrets and never changes unrelated errors',
    () {
      final classified = mpvOpenFailure(
        'stream',
        'No protocol handler found to open URL yingyu-disc://PRIVATE/clip/00001.m2ts?token=SECRET',
      );
      expect(classified, '播放内核未找到该读取通路的处理接口');
      expect(classified, isNot(contains('PRIVATE')));
      expect(classified, isNot(contains('SECRET')));
      expect(
        mpvOpenFailure('vd', 'No protocol handler found to open URL'),
        isNull,
      );
      expect(mpvOpenFailure('stream', 'Connection refused'), isNull);
      expect(isMpvErrorLog('stream', 'error', 'Connection refused'), true);
    },
  );
}
