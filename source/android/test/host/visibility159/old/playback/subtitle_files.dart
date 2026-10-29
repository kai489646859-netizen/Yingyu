import 'dart:async';
import 'dart:io';
import '../core/models.dart';
import 'disc_transport.dart' show ExactHttpUri;

/// Fetch only a chosen external subtitle. Accounts remain in the Emby origin,
/// and MPV receives a local temporary file, so subtitle HTTP failures cannot
/// masquerade as a failure of the video stream. No video route is accessed.
class SubtitleFiles {
  SubtitleFiles({
    this.maxBytes = 64 * 1024 * 1024,
    this.timeout = const Duration(seconds: 20),
  });
  final int maxBytes;
  final Duration timeout;
  final _clients = <HttpClient>{};
  final _files = <String, Future<File>>{};
  final _directories = <Directory>[];
  int _retainedBytes = 0;
  bool _closed = false;

  Future<File> load(String id, PlaybackRoute route, String codec) async {
    if (_closed) throw const AppFailure('字幕会话已关闭');
    final pending = _files.putIfAbsent(id, () => _fetch(route, codec));
    try {
      return await pending;
    } catch (_) {
      if (_files[id] == pending) _files.remove(id);
      rethrow;
    }
  }

  Future<File> _fetch(PlaybackRoute route, String codec) async {
    final client = HttpClient()..connectionTimeout = timeout;
    _clients.add(client);
    final deadline = Timer(timeout, () => client.close(force: true));
    Directory? directory;
    var complete = false;
    try {
      var target = route.url;
      final visited = <String>{};
      for (var hop = 0; hop < 8; hop++) {
        if (_closed) throw const AppFailure('字幕会话已关闭');
        if (!visited.add(target)) throw const AppFailure('外挂字幕发生重定向循环');
        final uri = ExactHttpUri(target);
        final request = await client.getUrl(uri).timeout(timeout);
        request.followRedirects = false;
        if (route.serverBase?.origin == uri.origin) {
          route.sameOriginHeaders.forEach(request.headers.set);
        }
        final response = await request.close().timeout(timeout);
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value('location');
          if (location == null) throw const AppFailure('外挂字幕重定向缺少目标');
          await response.listen((_) {}).cancel();
          target =
              RegExp(r'^https?://', caseSensitive: false).hasMatch(location)
              ? location
              : location.startsWith('//')
              ? '${uri.scheme}:$location'
              : uri.parsed.resolve(location).toString();
          continue;
        }
        if (response.statusCode != 200) {
          throw AppFailure('外挂字幕下载失败', status: response.statusCode);
        }
        if (response.contentLength > maxBytes) {
          throw AppFailure('外挂字幕超过 ${maxBytes ~/ (1024 * 1024)} MiB 上限');
        }
        directory = await Directory.systemTemp.createTemp('yingyu-sub-');
        _directories.add(directory);
        final extension = switch (codec.toLowerCase()) {
          'ass' || 'ssa' => codec.toLowerCase(),
          'webvtt' || 'vtt' => 'vtt',
          'hdmv_pgs_subtitle' || 'pgs' => 'sup',
          _ => 'srt',
        };
        final file = File('${directory.path}/subtitle.$extension');
        final sink = file.openWrite();
        var size = 0;
        try {
          await for (final chunk in response.timeout(timeout)) {
            if (_closed) throw const AppFailure('字幕会话已关闭');
            size += chunk.length;
            if (size > maxBytes || _retainedBytes + size > 128 * 1024 * 1024) {
              throw const AppFailure('外挂字幕缓存达到上限');
            }
            sink.add(chunk);
            // Apply disk backpressure without retaining the full subtitle.
            await sink.flush();
          }
        } finally {
          await sink.close();
        }
        if (size == 0) throw const AppFailure('外挂字幕内容为空');
        _retainedBytes += size;
        complete = true;
        return file;
      }
      throw const AppFailure('外挂字幕重定向次数过多');
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure('外挂字幕读取失败或超时，可手动重试');
    } finally {
      deadline.cancel();
      _clients.remove(client);
      client.close(force: true);
      if (!complete && directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
        _directories.remove(directory);
      }
    }
  }

  void cancel() {
    _closed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    cancel();
    for (final pending in _files.values.toList()) {
      try {
        await pending;
      } catch (_) {
        /* Download error is already reported. */
      }
    }
    for (final directory in _directories) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    _files.clear();
    _directories.clear();
  }
}
