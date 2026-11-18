import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../version.dart';

const _repository = 'kai489646859-netizen/Yingyu';
final _feed = Uri.https('api.github.com', '/repos/$_repository/releases', {
  'per_page': '30',
});
const _maxApk = 512 * 1024 * 1024;
const _timeout = Duration(seconds: 20);
final _versionPattern = RegExp(r'^([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})$');

int? _version(String value) {
  final match = _versionPattern.firstMatch(value);
  if (match == null) return null;
  return int.parse(match[1]!) * 10000000000 +
      int.parse(match[2]!) * 100000 +
      int.parse(match[3]!);
}

class AndroidRelease {
  const AndroidRelease(this.version, this.url, this.size, this.digest);
  final String version;
  final Uri url;
  final int size;
  final String digest;

  Map<String, Object> get publishedRow => {
    'draft': false,
    'prerelease': false,
    'tag_name': 'android-v$version',
    'assets': [
      {
        'name': 'Yingyu-$version.apk',
        'state': 'uploaded',
        'browser_download_url': url.toString(),
        'size': size,
        'digest': 'sha256:$digest',
      },
    ],
  };

  static AndroidRelease? newest(
    Object? releases, {
    String current = appVersion,
  }) {
    final installed = _version(current);
    if (releases is! List || installed == null) {
      throw const UpdateFailure('更新列表格式不正确');
    }
    AndroidRelease? best;
    var latest = installed;
    var unverified = installed;
    for (final row in releases) {
      if (row is! Map ||
          row['draft'] != false ||
          row['prerelease'] != false ||
          row['tag_name'] is! String) {
        continue;
      }
      final tag = row['tag_name'] as String;
      if (!tag.startsWith('android-v')) continue;
      final name = tag.substring('android-v'.length);
      final order = _version(name);
      if (order == null || order <= latest) continue;
      final assets = row['assets'];
      if (assets is! List) continue;
      final file = 'Yingyu-$name.apk';
      for (final asset in assets) {
        if (asset is! Map ||
            asset['name'] != file ||
            asset['state'] != 'uploaded') {
          continue;
        }
        final expected = Uri.https(
          'github.com',
          '/$_repository/releases/download/$tag/$file',
        );
        final size = asset['size'], digest = asset['digest'];
        if (asset['browser_download_url'] != expected.toString() ||
            size is! int ||
            size <= 0 ||
            size > _maxApk ||
            digest is! String ||
            !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(digest)) {
          if (order > unverified) unverified = order;
          continue;
        }
        latest = order;
        best = AndroidRelease(name, expected, size, digest.substring(7));
        break;
      }
    }
    if (unverified > latest) throw const UpdateFailure('新版缺少有效的 APK 校验信息');
    return best;
  }
}

class UpdateFailure implements Exception {
  const UpdateFailure(this.message);
  final String message;
}

class _RetryUpdate extends UpdateFailure {
  const _RetryUpdate(super.message, {this.restart = false});
  final bool restart;
}

/// One application-owned transfer. Partial bytes survive page and process exits.
class AndroidAppUpdate extends ChangeNotifier {
  AndroidAppUpdate({
    HttpClient Function()? createClient,
    this.retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
  }) : _createClient = createClient ?? _client;
  static final shared = AndroidAppUpdate();
  static const channel = MethodChannel('yingyu/app-update');
  AndroidRelease? release;
  int bytes = 0;
  bool checking = false,
      downloading = false,
      verified = false,
      installing = false;
  String? message;
  HttpClient? _transfer;
  Completer<void>? _paused;
  bool _stop = false;
  bool _restored = false;
  final HttpClient Function() _createClient;
  final List<Duration> retryDelays;

  static HttpClient _client() => HttpClient()
    ..connectionTimeout = _timeout
    ..autoUncompress = false;

  static bool assetHost(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      !uri.hasFragment &&
      const {
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      }.contains(uri.host);

  Future<Directory> _directory() async {
    final path = await channel.invokeMethod<String>('directory');
    if (path == null || path.isEmpty) throw const UpdateFailure('无法打开下载目录');
    return Directory(path).create(recursive: true);
  }

  Future<void> restore() async {
    if (_restored || checking || downloading || installing) return;
    _restored = true;
    checking = true;
    notifyListeners();
    try {
      final directory = await _directory();
      final metadata = File('${directory.path}/release.json');
      if (!await metadata.exists() || await metadata.length() > 4096) return;
      final candidate = AndroidRelease.newest([
        jsonDecode(await metadata.readAsString()),
      ]);
      await _activate(directory, candidate);
    } catch (_) {
      // No network request on open; checking again can replace a stale record.
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<void> _activate(Directory directory, AndroidRelease? selected) async {
    release = selected;
    verified = false;
    bytes = 0;
    await _prune(directory, selected);
    if (selected == null) return;
    final apk = File('${directory.path}/${selected.digest}.apk');
    final partial = File('${directory.path}/${selected.digest}.part');
    verified = await _checkFile(apk, selected);
    if (!verified && await apk.exists()) await apk.delete();
    bytes = verified
        ? selected.size
        : (await partial.exists() ? await partial.length() : 0);
    if (bytes > selected.size) {
      await partial.delete();
      bytes = 0;
    }
  }

  Future<void> check({void Function(String)? diagnostic}) async {
    if (checking || downloading || installing) return;
    checking = true;
    message = null;
    notifyListeners();
    final client = _createClient();
    try {
      final request = await client.getUrl(_feed).timeout(_timeout);
      request.followRedirects = false;
      request.headers.set('Accept', 'application/vnd.github+json');
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      request.headers.set('User-Agent', 'Yingyu-Android/$appVersion');
      final response = await request.close().timeout(_timeout);
      diagnostic?.call('检查版本 · GitHub API · HTTP ${response.statusCode}');
      if (response.statusCode != 200) {
        final status = response.statusCode;
        if (status == 429 ||
            (status == 403 &&
                response.headers.value('x-ratelimit-remaining') == '0')) {
          throw UpdateFailure('GitHub 更新查询暂时限流（HTTP $status），请稍后重试');
        }
        throw UpdateFailure('无法读取发布列表（HTTP $status）');
      }
      final buffer = BytesBuilder(copy: false);
      await for (final part in response.timeout(_timeout)) {
        if (buffer.length + part.length > 2 * 1024 * 1024) {
          throw const UpdateFailure('发布列表超出大小限制');
        }
        buffer.add(part);
      }
      final selected = AndroidRelease.newest(
        jsonDecode(utf8.decode(buffer.takeBytes())),
      );
      final directory = await _directory();
      final metadata = File('${directory.path}/release.json');
      if (selected == null) {
        message = '暂无比当前版本新的正式安卓包';
        diagnostic?.call('检查版本 · 未找到更高版本的正式安卓包');
        if (await metadata.exists()) await metadata.delete();
      } else {
        final pending = File('${metadata.path}.tmp');
        await pending.writeAsString(
          jsonEncode(selected.publishedRow),
          flush: true,
        );
        await pending.rename(metadata.path);
      }
      await _activate(directory, selected);
    } on UpdateFailure catch (error) {
      message = error.message;
    } catch (error) {
      final reason = _failureKind(error);
      diagnostic?.call('检查版本 · GitHub API · $reason');
      message = '检查更新失败（$reason）';
    } finally {
      client.close(force: true);
      checking = false;
      notifyListeners();
    }
  }

  Future<void> _prune(Directory directory, AndroidRelease? keep) async {
    await for (final file in directory.list(followLinks: false)) {
      final name = file.uri.pathSegments.last;
      if (file is File &&
          RegExp(r'^[0-9a-f]{64}\.(apk|part)$').hasMatch(name) &&
          (keep == null || !name.startsWith(keep.digest))) {
        await file.delete();
      }
    }
  }

  static Future<bool> _checkFile(File file, AndroidRelease asset) async =>
      await file.exists() &&
      await file.length() == asset.size &&
      (await sha256.bind(file.openRead()).first).toString() == asset.digest;

  Future<HttpClientResponse> _response(
    HttpClient client,
    Uri url,
    int start,
    void Function(String)? diagnostic,
  ) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (!assetHost(url)) throw const UpdateFailure('发布包跳转地址无效');
      HttpClientResponse response;
      try {
        final request = await client.getUrl(url).timeout(_timeout);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (start > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
        }
        response = await request.close().timeout(_timeout);
      } catch (error) {
        diagnostic?.call('下载安装包 · ${url.host} · ${_failureKind(error)}');
        rethrow;
      }
      diagnostic?.call('下载安装包 · ${url.host} · HTTP ${response.statusCode}');
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      final next = response.headers.value(HttpHeaders.locationHeader);
      if (next == null) break;
      await response.listen((_) {}).cancel();
      url = url.resolve(next);
    }
    throw const UpdateFailure('下载跳转失败');
  }

  static bool exactRange(String? value, int start, int size) =>
      value == 'bytes $start-${size - 1}/$size';

  static String _failureKind(Object error) => switch (error) {
    TimeoutException() => '连接或响应超时',
    HandshakeException() => 'TLS 握手失败',
    SocketException() => 'DNS 或网络连接失败',
    HttpException() => 'HTTP 连接中断',
    FormatException() => '发布列表格式错误',
    FileSystemException() => '本机存储错误',
    _ => '请求未完成',
  };

  Future<void> download({void Function(String)? diagnostic}) async {
    final asset = release;
    if (asset == null || checking || downloading || installing || verified) {
      return;
    }
    downloading = true;
    _stop = false;
    message = null;
    final paused = _paused = Completer<void>();
    notifyListeners();
    try {
      final directory = await _directory();
      final part = File('${directory.path}/${asset.digest}.part');
      final apk = File('${directory.path}/${asset.digest}.apk');
      bytes = await part.exists() ? await part.length() : 0;
      if (bytes > asset.size) {
        await part.delete();
        bytes = 0;
      }
      var retry = 0;
      var restarted = false;
      while (bytes < asset.size && !_stop) {
        final client = _transfer = _createClient();
        try {
          // Reopen the official URL on every attempt. CDN redirects expire.
          await _receive(client, asset, part, diagnostic);
          break;
        } catch (error) {
          if (_stop) return;
          if (error is _RetryUpdate && error.restart) {
            if (restarted) rethrow;
            restarted = true;
            if (await part.exists()) await part.delete();
            bytes = 0;
            message = '续传位置失效，正在从头下载';
            notifyListeners();
            continue;
          }
          if (error is! _RetryUpdate &&
              error is! SocketException &&
              error is! HttpException &&
              error is! TimeoutException) {
            rethrow;
          }
          final reason = error is _RetryUpdate
              ? error.message
              : _failureKind(error);
          diagnostic?.call('下载重试 · $reason · 已接收 $bytes 字节');
          if (retry >= retryDelays.length) {
            throw UpdateFailure('$reason，已保留可续传的进度');
          }
          message = '$reason，正在准备自动续传（${retry + 1}/${retryDelays.length}）';
          notifyListeners();
        } finally {
          _transfer = null;
          client.close(force: true);
        }
        await paused.future.timeout(retryDelays[retry++], onTimeout: () {});
        if (!_stop) {
          message = null;
          notifyListeners();
        }
      }
      if (_stop) return;
      message = '正在校验安装包…';
      notifyListeners();
      final valid = await _checkFile(part, asset);
      if (_stop) return;
      if (!valid) {
        await part.delete();
        bytes = 0;
        throw const UpdateFailure('SHA-256 校验失败，安装包已丢弃');
      }
      await part.rename(apk.path);
      verified = true;
      message = '校验通过，可以安装';
    } on UpdateFailure catch (error) {
      message = error.message;
    } on FileSystemException {
      message = '无法保存安装包，请检查剩余存储空间';
    } catch (error) {
      final reason = _failureKind(error);
      diagnostic?.call('下载安装包 · $reason');
      message = '下载未完成（$reason），可以继续下载';
    } finally {
      if (_stop) message = '已暂停，可以继续下载';
      _paused = null;
      downloading = false;
      notifyListeners();
    }
  }

  Future<void> _receive(
    HttpClient client,
    AndroidRelease asset,
    File part,
    void Function(String)? diagnostic,
  ) async {
    final response = await _response(client, asset.url, bytes, diagnostic);
    final status = response.statusCode;
    if (status == 429) {
      throw const UpdateFailure('下载服务暂时限流（HTTP 429），请稍后继续');
    }
    if (status == 408 || status == 403 || (status >= 500 && status < 600)) {
      throw _RetryUpdate('下载服务暂时不可用（HTTP $status）');
    }
    if (status == 416 && bytes > 0) {
      throw const _RetryUpdate('续传区间已失效（HTTP 416）', restart: true);
    }
    if (status != 200 && status != 206) {
      throw UpdateFailure('下载服务响应失败（HTTP $status）');
    }
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding != 'identity') {
      throw const UpdateFailure('下载响应使用了不支持的编码');
    }
    if (status == 200) {
      bytes = 0;
    } else if (bytes == 0 ||
        !exactRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
          bytes,
          asset.size,
        )) {
      if (bytes > 0) {
        throw const _RetryUpdate('服务器未确认续传范围', restart: true);
      }
      throw const UpdateFailure('服务器未返回完整的安装包');
    }
    if (response.contentLength >= 0 &&
        response.contentLength != asset.size - bytes) {
      throw const UpdateFailure('下载文件大小与发布信息不一致');
    }
    if (_stop) return;
    final file = await part.open(
      mode: bytes == 0 ? FileMode.write : FileMode.append,
    );
    var reported = bytes;
    try {
      await for (final chunk in response.timeout(_timeout)) {
        if (_stop) break;
        if (bytes + chunk.length > asset.size) {
          throw const UpdateFailure('安装包超出预期大小');
        }
        await file.writeFrom(chunk);
        bytes += chunk.length;
        if (bytes - reported >= 256 * 1024) {
          reported = bytes;
          notifyListeners();
        }
      }
    } finally {
      await file.close();
    }
    if (!_stop && bytes != asset.size) {
      throw const _RetryUpdate('下载连接提前结束');
    }
  }

  void pause() {
    if (!downloading || _stop) return;
    _stop = true;
    _paused?.complete();
    _transfer?.close(force: true);
  }

  Future<void> discard() async {
    final asset = release;
    if (asset == null || checking || downloading || installing) return;
    checking = true;
    notifyListeners();
    try {
      final directory = await _directory();
      for (final extension in ['apk', 'part']) {
        final file = File('${directory.path}/${asset.digest}.$extension');
        if (await file.exists()) await file.delete();
      }
      bytes = 0;
      verified = false;
      message = '下载已删除';
    } catch (_) {
      message = '暂时无法删除下载';
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<void> install() async {
    final asset = release;
    if (asset == null || !verified || checking || downloading || installing) {
      return;
    }
    installing = true;
    message = '正在准备系统安装…';
    notifyListeners();
    try {
      if (await channel.invokeMethod<bool>('permission') != true) {
        message = '授权后请返回映屿，再点安装';
        await channel.invokeMethod<void>('settings');
      } else {
        await channel.invokeMethod<void>('install', {
          'version': asset.version,
          'digest': asset.digest,
        });
        message = '请在 Android 安装界面确认';
      }
    } on PlatformException catch (error) {
      message = error.message ?? '无法启动系统安装';
    } catch (_) {
      message = '无法启动系统安装';
    } finally {
      installing = false;
      notifyListeners();
    }
  }

  Future<void> refreshInstallState() async {
    try {
      _installState(await channel.invokeMethod<String>('installState'));
    } catch (_) {}
  }

  void observeInstallState(bool active) {
    channel.setMethodCallHandler(
      active
          ? (call) async {
              if (call.method == 'changed') _installState(call.arguments);
            }
          : null,
    );
  }

  void _installState(Object? status) {
    final label = switch (status) {
      'cancelled' => '已取消安装，可以再次安装',
      'failed' => '系统安装失败，可以再次安装',
      'installed' => '系统已安装新版',
      _ => null,
    };
    if (!checking && !downloading && !installing && label != null) {
      message = label;
      notifyListeners();
    }
  }
}
