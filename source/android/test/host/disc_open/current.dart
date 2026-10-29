// Generated from production open(): see tools/prepare_disc_open_replay.py.
// IO substitutes capture commands and temporary playlist data; no player runs.
// ignore_for_file: non_constant_identifier_names, unnecessary_import, unused_import, library_private_types_in_public_api, depend_on_referenced_packages
import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/models/playable.dart';
import 'package:uri_parser/uri_parser.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
String addPrefix(String path) => path;
class _Lock { Future<void> synchronized(Future<void> Function() f) => f(); }
class TempFile {
  static final files = <String, TempFile>{};
  final String path;
  String text = '';
  TempFile(this.path);
  static Future<TempFile> create() async {
    final f = TempFile('/synthetic-list-${files.length}.txt'); files[f.path] = f; return f;
  }
  Future<void> write_(String value) async { text = value; }
  Future<void> delete_() async {}
}
class ReplayPlayer {
  bool disposed = false, isPlayingStateChangeAllowed = false;
  final waitForPlayerInitialization = Future<void>.value();
  final waitForVideoControllerInitializationIfAttached = Future<void>.value();
  final lock = _Lock();
  var current = <Media>[];
  var state = const PlayerState();
  final playlistController = StreamController<Playlist>.broadcast();
  final playingController = StreamController<bool>.broadcast();
  final commands = <List<String>>[];
  final properties = <String,Object>{};
  Future<void> stop({bool open = false, bool synchronized = true, bool notify = true}) async { commands.add(['stop']); }
  Future<void> _setPropertyFlag(String key, bool value) async { properties[key] = value; }
  Future<void> _setPropertyInt64(String key, int value) async { properties[key] = value; }
  Future<void> _command(List<String> values) async { commands.add(values); }
  List<String> get load => commands.singleWhere((c) => c.first == 'loadfile' || c.first == 'loadlist');
  String get target => load.first == 'loadfile' ? load[1] : TempFile.files[load[1]]!.text.trimRight();
  Future<void> close() async { await playlistController.close(); await playingController.close(); }
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) {
    Future<void> function() async {
      if (disposed) {
        throw AssertionError('[Player] has been disposed');
      }
      await waitForPlayerInitialization;
      await waitForVideoControllerInitializationIfAttached;

      final int index;
      final List<Media> playlist = <Media>[];
      if (playable is Media) {
        index = 0;
        playlist.add(playable);
      } else if (playable is Playlist) {
        index = playable.index;
        playlist.addAll(playable.medias);
      } else {
        index = -1;
      }

      // Keep these [Media] objects in memory.
      current = playlist;

      // External List<Media>:
      // ---------------------------------------------
      state = state.copyWith(playlist: Playlist(playlist, index: index));
      if (!playlistController.isClosed) {
        playlistController.add(Playlist(playlist, index: index));
      }
      // ---------------------------------------------

      // Restore original state & reset public [PlayerState] & [PlayerStream] values e.g. width=null, height=null, subtitle=['', ''] etc.
      await stop(
        open: true,
        synchronized: false,
      );

      // Enter paused state.
      await _setPropertyFlag('pause', true);

      if (playlist.any((media) => media.uri.startsWith('fd://')) ||
          playlist.length == 1 && _yingyuNativeDiscDirectOpen(playlist.single)) {
        // The fd:// scheme is used to reference content:// URIs on Android.
        // The loadlist command does not support this by default, yielding "Refusing to load potentially unsafe URL from a playlist."
        // So, we fallback to loading each file individually.
        for (int i = 0; i < playlist.length; i++) {
          await _command(
            [
              'loadfile',
              _sanitizeUri(playlist[i].uri),
              'append',
            ],
          );
        }
      } else {
        final file = await TempFile.create();
        final buffer = StringBuffer();
        for (final media in playlist) {
          buffer.writeln(_sanitizeUri(media.uri));
        }
        final list = buffer.toString();

        await file.write_(list);

        await _command(
          [
            'loadlist',
            file.path,
            'append',
          ],
        );

        Future.delayed(const Duration(seconds: 5), () {
          file.delete_();
        });
      }

      // If [play] is `true`, then exit paused state.
      if (play) {
        isPlayingStateChangeAllowed = true;
        await _setPropertyFlag('pause', false);
        state = state.copyWith(playing: true);
        if (!playingController.isClosed) {
          playingController.add(true);
        }
      }

      // Jump to the specified [index] (in both cases either [play] is `true` or `false`).
      await _setPropertyInt64('playlist-pos', index);
    }

    if (synchronized) {
      return lock.synchronized(function);
    } else {
      return function();
    }
  }
  String _sanitizeUri(String uri) {
    // Append \\?\ prefix on Windows to support long file paths.
    final parser = URIParser(uri);
    switch (parser.type) {
      case URIType.file:
        return addPrefix(parser.file!.path);
      case URIType.directory:
        return addPrefix(parser.directory!.path);
      case URIType.network:
        // Yingyu: do not normalize a signed network URL again at loadlist.
        return uri;
      default:
        return uri;
    }
  }
}
bool _yingyuNativeDiscDirectOpen(Media media) {
  final id = media.extras?['yingyuNativeDiscSession'];
  if (id is! String || id.length != 32 || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
    return false;
  }
  const prefix = 'edl://!no_chapters;';
  if (!media.uri.startsWith(prefix)) return false;
  final segments = media.uri.substring(prefix.length).split(';');
  if (segments.isEmpty || segments.length > 4096) return false;
  final pattern = RegExp(
    '^%62%yingyu-disc://$id/clip/'
    r'[0-9]{5}\.m2ts,[0-9]+\.[0-9]{6},[0-9]+\.[0-9]{6}$',
  );
  return segments.every((segment) {
    final match = pattern.firstMatch(segment);
    if (match == null || match.end != segment.length) return false;
    final times = segment.split(',');
    final start = double.tryParse(times[1]);
    final length = double.tryParse(times[2]);
    return start != null &&
        start.isFinite &&
        length != null &&
        length.isFinite &&
        length > 0;
  });
}
