import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/http_diagnostics.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_stream.dart';
import 'package:yingyu/playback/disc_ordered_reader.dart';
import 'package:yingyu/playback/tracks.dart';
import 'package:yingyu/playback/byte_cache.dart';
import 'package:yingyu/playback/cached_reader.dart';
import 'package:yingyu/playback/disc_seek_index.dart';

/// HttpClient serializes Uri.path/query. Keep signed HTTP request targets byte
/// for byte; Uri.parse alone normalizes percent escapes (including %2f/%7e).
/// Connection/TLS/origin decisions still use Dart's parsed authority.
class ExactHttpUri implements Uri {
  ExactHttpUri(String value) : raw = _requestAddress(value) {
    parsed = Uri.parse(raw);
    if (!const {'http', 'https'}.contains(parsed.scheme) ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(raw)) {
      throw const AppFailure('原盘 HTTP 地址无效');
    }
    final match = RegExp(
      r'^https?://[^/?#]+([^?#]*)(?:\?([^#]*))?$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match == null) throw const AppFailure('原盘 HTTP 地址无效');
    path = match[1]!.isEmpty ? '/' : match[1]!;
    query = match[2] ?? '';
    hasQuery = match[2] != null;
  }

  static String _requestAddress(String value) {
    final address = value.split('#').first;
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(address)) {
      throw const AppFailure('原盘 HTTP 地址无效');
    }
    final authority = RegExp(
      r'^https?://[^/?#]+',
      caseSensitive: false,
    ).firstMatch(address);
    if (authority == null) return address;
    final result = StringBuffer(address.substring(0, authority.end));
    // Match the fixed SDK's path/query character sets and bare-percent
    // handling, without its normalization of valid signed escapes. HttpClient
    // writes these components as bytes, so literal text needs UTF-8 escaping.
    const pathChars = r"!$&'()*+,-./:;=@_~";
    final runes = address
        .substring(authority.end)
        .runes
        .toList(growable: false);
    bool hex(int rune) =>
        rune >= 0x30 && rune <= 0x39 ||
        rune >= 0x41 && rune <= 0x46 ||
        rune >= 0x61 && rune <= 0x66;
    var inQuery = false;
    for (var index = 0; index < runes.length; index++) {
      final rune = runes[index];
      if (rune == 0x3f && !inQuery) {
        inQuery = true;
        result.writeCharCode(rune);
      } else if (rune == 0x25) {
        if (index + 2 < runes.length &&
            hex(runes[index + 1]) &&
            hex(runes[index + 2])) {
          result.write(String.fromCharCodes(runes.sublist(index, index + 3)));
          index += 2;
        } else {
          result.write('%25');
        }
      } else if (rune == 0x5c && !inQuery) {
        // The SDK treats a literal path backslash as a directory separator;
        // the same character inside a query remains data and is escaped.
        result.write('/');
      } else if (rune >= 0x30 && rune <= 0x39 ||
          rune >= 0x41 && rune <= 0x5a ||
          rune >= 0x61 && rune <= 0x7a ||
          rune < 0x80 && pathChars.contains(String.fromCharCode(rune)) ||
          inQuery && rune == 0x3f) {
        result.writeCharCode(rune);
      } else {
        result.write(Uri.encodeComponent(String.fromCharCode(rune)));
      }
    }
    return result.toString();
  }

  final String raw;
  late final Uri parsed;
  @override
  late final String path, query;
  @override
  late final bool hasQuery;
  @override
  String get scheme => parsed.scheme;
  @override
  String get host => parsed.host;
  @override
  int get port => parsed.port;
  @override
  String get userInfo => '';
  @override
  String get origin => parsed.origin;
  @override
  String get authority => parsed.authority;
  @override
  bool get hasAuthority => true;
  @override
  bool get hasPort => parsed.hasPort;
  @override
  bool get isAbsolute => true;
  @override
  String get fragment => '';
  @override
  bool get hasFragment => false;
  @override
  bool isScheme(String value) => parsed.isScheme(value);
  @override
  Uri removeFragment() => this;
  @override
  ExactHttpUri resolve(String reference) {
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(reference)) {
      throw const AppFailure('媒体重定向地址无效');
    }
    final parsedReference = Uri.tryParse(reference);
    if (parsedReference == null) {
      throw const AppFailure('媒体重定向地址无效');
    }
    if (parsedReference.hasScheme) return ExactHttpUri(reference);
    if (reference.startsWith('//')) {
      return ExactHttpUri('$scheme:$reference');
    }
    // RFC 3986 relative resolution must remove literal dot segments without
    // decoding/re-encoding an opaque signed path, query or repeated parameter.
    final address = reference.split('#').first;
    final queryAt = address.indexOf('?');
    final relativePath = (queryAt < 0 ? address : address.substring(0, queryAt))
        .replaceAll(r'\', '/');
    final relativeQuery = queryAt < 0 ? null : address.substring(queryAt);
    if (relativePath.isEmpty) {
      return ExactHttpUri(
        '$scheme://$authority$path${relativeQuery ?? (hasQuery ? '?$query' : '')}',
      );
    }
    var input = relativePath.startsWith('/')
        ? relativePath
        : '${path.substring(0, path.lastIndexOf('/') + 1)}$relativePath';
    var output = '';
    while (input.isNotEmpty) {
      if (input.startsWith('../')) {
        input = input.substring(3);
      } else if (input.startsWith('./')) {
        input = input.substring(2);
      } else if (input.startsWith('/./')) {
        input = input.substring(2);
      } else if (input == '/.') {
        input = '/';
      } else if (input.startsWith('/../') || input == '/..') {
        input = input == '/..' ? '/' : input.substring(3);
        final slash = output.lastIndexOf('/');
        output = slash < 0 ? '' : output.substring(0, slash);
      } else if (input == '.' || input == '..') {
        input = '';
      } else {
        final slash = input.indexOf('/', input.startsWith('/') ? 1 : 0);
        output += slash < 0 ? input : input.substring(0, slash);
        input = slash < 0 ? '' : input.substring(slash);
      }
    }
    return ExactHttpUri('$scheme://$authority$output${relativeQuery ?? ''}');
  }

  @override
  String toString() => raw;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DiscClip {
  DiscClip(Json json)
    : id = json['id']?.toString() ?? '',
      start = integer(json['in']),
      end = integer(json['out']) {
    if (!RegExp(r'^\d{5}$').hasMatch(id) || start < 0 || end <= start) {
      throw const AppFailure('原盘播放列表包含无效片段');
    }
  }
  final String id;
  final int start, end;
}

class DiscTitle {
  DiscTitle(Json json)
    : playlist = integer(json['playlist']),
      mainFeature = json['main'] == true,
      duration = integer(json['duration']),
      audioLanguages = discTrackLanguages(json['audio']),
      subtitleLanguages = discTrackLanguages(json['subtitles']),
      clips = objects(json['clips']).map(DiscClip.new).toList(),
      chapters = (json['chapters'] as List? ?? []).map(integer).toList() {
    if (playlist < 0 ||
        playlist > 99999 ||
        duration <= 0 ||
        clips.isEmpty ||
        clips.length > 4096 ||
        (clips.fold<int>(0, (total, clip) => total + clip.end - clip.start) -
                    duration)
                .abs() >
            90000) {
      throw const AppFailure('原盘播放列表时长或片段数量无效');
    }
  }
  final int playlist, duration;
  final bool mainFeature;
  final Map<int, String> audioLanguages, subtitleLanguages;
  final List<DiscClip> clips;
  final List<int> chapters;
  String get label =>
      '播放列表 ${playlist.toString().padLeft(5, '0')} · ${duration ~/ 90000 ~/ 60} 分钟';
  String edl(String base) {
    // MPV's EDL uses demuxer timestamps when start is explicit, matching
    // libbluray's in_time/out_time in 90 kHz units (not file-relative zero).
    final segments = clips
        .map((clip) {
          final url = '$base/clip/${clip.id}.m2ts';
          return '%${utf8.encode(url).length}%$url,${(clip.start / 90000).toStringAsFixed(6)},${((clip.end - clip.start) / 90000).toStringAsFixed(6)}';
        })
        .join(';');
    return 'edl://!no_chapters;$segments';
  }
}

List<DiscTitle> readableDiscTitles(
  dynamic value, {
  void Function(int)? onRejected,
}) {
  if (value is! List || value.length > 4096) {
    throw const AppFailure('原盘播放列表数量无效');
  }
  final result = <DiscTitle>[];
  var rejected = 0;
  for (final row in value) {
    try {
      result.add(DiscTitle(object(row)));
    } on AppFailure {
      rejected++;
    }
  }
  if (rejected > 0) onRejected?.call(rejected);
  if (result.isEmpty) throw const AppFailure('原盘没有有效的可播放标题');
  return result..sort((a, b) => b.duration.compareTo(a.duration));
}

/// Strict single byte ranges for the loopback MPV view. No full-disc buffering.
({int start, int end})? discByteRange(String? value, int size) {
  if (size <= 0) return null;
  if (value == null) return (start: 0, end: size - 1);
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
  if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) return null;
  if (match[1]!.isEmpty) {
    final suffix = int.tryParse(match[2]!);
    if (suffix == null || suffix <= 0) return null;
    return (start: (size - suffix).clamp(0, size - 1), end: size - 1);
  }
  final start = int.tryParse(match[1]!);
  final end = match[2]!.isEmpty ? size - 1 : int.tryParse(match[2]!);
  if (start == null || end == null || start >= size || end < start) return null;
  return (start: start, end: end.clamp(start, size - 1));
}

class DiscTransport {
  DiscTransport(
    this.route, {
    required this.kind,
    this.log,
    this.onStage,
    this.address,
    this.onFailure,
    this.cacheBytes = 32 * 1024 * 1024,
    this.persistentCache,
    this.cacheScope = '',
    this.backgroundOutput = false,
    this.directInput = false,
    this.nativeInvoke,
    String? sessionId,
  }) : id = sessionId ?? newId();
  final PlaybackRoute route;
  final DiscKind kind;
  final String? address;
  final DiagnosticLog? log;
  final void Function(String)? onStage;
  final void Function(String)? onFailure;
  final int cacheBytes;
  final PlaybackByteCache? persistentCache;
  final String cacheScope;
  final bool backgroundOutput;
  final bool directInput;
  String seekIndex = '';
  // Control-only RPC when the HTTP data plane runs in its own isolate. The
  // production background output never returns video bytes through this call.
  final Future<Object?> Function(String, Map<String, Object?>)? nativeInvoke;
  Timer? _outputTimer;
  bool _outputPolling = false;
  String _outputHealth = '';
  final _persistentReaders = <String, CachedMediaReader>{};
  int _persistentSeconds = 0;
  String? _persistentActive;
  void suspendPersistentReadAhead() {
    _persistentSeconds = 0;
    for (final reader in _persistentReaders.values) {
      reader.suspend();
    }
  }

  void configurePersistentReadAhead(int seconds) {
    _persistentSeconds = seconds;
    for (final entry in _persistentReaders.entries) {
      if (entry.key == _persistentActive) {
        _updatePersistent(entry.key, entry.value);
      }
    }
  }

  void stopPersistentReadAhead() {
    _persistentSeconds = 0;
    for (final reader in _persistentReaders.values) {
      reader.stopWarming();
    }
  }

  void _updatePersistent(String relative, CachedMediaReader reader) {
    final title = selected;
    if (_persistentSeconds == 0 || title == null || reader.total <= 0) return;
    final clip = title.clips
        .where((clip) => relative.endsWith('${clip.id}.m2ts'))
        .firstOrNull;
    final ticks = clip == null ? title.duration : clip.end - clip.start;
    if (ticks <= 0) return;
    final bytes = (reader.total * _persistentSeconds * 90000 / ticks * 1.15)
        .ceil();
    reader.configureAhead(bytes.clamp(0, reader.total));
  }

  late final _rangeCache = DiscRangeCache(
    _fetchBlock,
    maxBytes: cacheBytes,
    progressiveFetch: persistentCache == null ? _fetchProgressiveBlock : null,
  );
  late final _streamReader = DiscOrderedReader(
    _openStream,
    maxBytes: cacheBytes * 3 ~/ 2,
    openPart: (path, start, end, identity, token) =>
        _openRange(path, start, end, identity, token),
    onDiagnostic: record,
    onResume: () {
      record('原盘媒体连接中断；仅向已解析的外部目标从断点续读一次，不重新访问 STRM 入口');
    },
  );
  static const channel = MethodChannel('yingyu/disc');
  final String id;
  HttpServer? _server;
  final _clients = <HttpClient>{};
  final _idleClients = <HttpClient>[];
  bool _closed = false;
  String? _folder;
  String? failure;
  final _clipIds = <String>{};
  final _sizes = <String, int>{};
  // A playback session never evicts or refreshes a resolved STRM entry. The
  // future also joins concurrent first reads, before any redirect is known.
  final _resolvedTargets = <String, Future<String>>{};
  final _targetFailures = <String, AppFailure>{};
  final _redirectEntries = <String>{};
  final _orderedIdentities = <String, DiscStreamIdentity>{};
  int _readCount = 0, _lastReadLog = 0;
  int _downloadBytes = 0, _downloadCount = 0, _lastBodyLog = 0;
  bool _failedPlayback = false;
  int _clipSequence = 0, _lastClipLog = 0, _inputSequence = 0;
  int _inputWaitMicroseconds = 0, _inputWriteMicroseconds = 0;
  final _activeClips = <int, _ClipTransfer>{};
  List<DiscTitle> titles = [];
  DiscTitle? selected;
  late String base;
  String get source => address ?? route.url;

  Future<void> refreshReadHealth() async {}

  String get readHealth =>
      '已交付数据=$_downloadCount 块/${(_downloadBytes / 1048576).toStringAsFixed(1)} MiB；'
      '连续媒体请求=${_streamReader.openedResponses}；复用数据块=${_streamReader.reusedBlocks}；'
      '读取通道=${_streamReader.mode}；活跃媒体响应=${_streamReader.activeResponses}；'
      '峰值媒体响应=${_streamReader.peakResponses}；顺序预读内存=${_streamReader.retainedBytes ~/ 1048576} MiB；'
      '${_streamReader.deliveryHealth}；'
      '渐进交付=${_rangeCache.progressiveReturns} 次；'
      '缓存交付复制累计=${_rangeCache.copyMicroseconds ~/ 1000} ms；'
      '${_streamReader.metrics.health}；$_outputHealth'
      '原盘输入等待累计=${_inputWaitMicroseconds ~/ 1000} ms；'
      '原盘输入写出累计=${_inputWriteMicroseconds ~/ 1000} ms；'
      '${directInput ? '原生直读使用顺序队列与最多 8 MiB 原生回读页，无中间 HTTP 块缓存' : _rangeHealth}';

  String get _rangeHealth =>
      'HTTP 缓存=${(_rangeCache.cachedBytes / 1048576).toStringAsFixed(1)} MiB；'
      '命中=${_rangeCache.hits}；未命中=${_rangeCache.misses}；待处理块=${_rangeCache.activeRequests}；'
      '峰值待处理块=${_rangeCache.peakRequests}；当前等块=${_rangeCache.waitingReads}；'
      '累计等块=${(_rangeCache.demandWaitMicroseconds / 1000000).toStringAsFixed(2)} 秒；'
      '已供给=${(_rangeCache.servedBytes / 1048576).toStringAsFixed(1)} MiB；'
      '预读=${_rangeCache.aheadBlocks} 块';

  double _speed = 1;
  void setBuffering(bool value) => _streamReader.setBuffering(value);
  void setSpeed(double speed) {
    if (!speed.isFinite || speed < .5 || speed > 3) return;
    _speed = speed;
    _streamReader.setSpeed(speed);
    if (!directInput) _rangeCache.setSpeed(speed);
  }

  int get _transferBytes => _speed > 2
      ? 1024 * 1024
      : _speed > 1
      ? 512 * 1024
      : 256 * 1024;
  void resetReadAhead() {
    _rangeCache.resetReadAhead();
    // Keep a currently demanded input alive until MPV replaces its output
    // request. Obsolete cache jobs cancel their own producer; an actual new
    // position retires any remaining queue before opening another response.
  }

  Future<void> _pollOutput() async {
    if (_closed || _outputPolling) return;
    _outputPolling = true;
    try {
      final status = await _native<Map<Object?, Object?>>('outputStatus');
      if (_closed || status == null) return;
      if (status['error'] != null || status['failed'] == true) {
        _playbackFailed(AppFailure(failure ?? '原盘后台读取失败，请重试'));
        return;
      }
      final bytes = integer(status['bytes']);
      _outputHealth =
          '后台直出=${(bytes / 1048576).toStringAsFixed(2)} MiB；'
          '后台读取=${integer(status['readMs'])} ms；后台写出=${integer(status['writeMs'])} ms；'
          '后台片段请求=${integer(status['requests'])}；后台活动=${integer(status['active'])}；';
    } catch (error) {
      if (!_closed) _playbackFailed(error);
    } finally {
      _outputPolling = false;
    }
  }

  void _playbackFailed(Object error) {
    if (_closed || _failedPlayback) return;
    _failedPlayback = true;
    failure = redactLog(safeError(error), secrets: route.diagnosticSecrets);
    onFailure?.call(failure!);
  }

  void _recordBody(int bytes, Stopwatch watch) {
    _downloadBytes += bytes;
    _downloadCount++;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastBodyLog < 5000 && watch.elapsedMilliseconds < 5000) return;
    _lastBodyLog = now;
    final seconds = watch.elapsedMicroseconds / 1000000;
    record(
      '原盘数据就绪：$bytes 字节；读取等待=${watch.elapsedMilliseconds} ms；'
      '本块供给均速=${seconds > 0 ? (bytes / 1048576 / seconds).toStringAsFixed(2) : "未知"} MiB/s；$readHealth',
    );
  }

  void record(String message, {bool error = false}) => log?.add(
    LogArea.player,
    redactLog(message, secrets: route.diagnosticSecrets),
    level: error ? LogLevel.error : LogLevel.info,
  );
  Future<T?> _native<T>(
    String method, [
    Map<String, Object?> values = const {},
  ]) async {
    try {
      final arguments = <String, Object?>{'id': id, ...values};
      final invoke = nativeInvoke;
      if (invoke != null) return await invoke(method, arguments) as T?;
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw AppFailure(failure ?? error.message ?? '原盘组件操作失败');
    }
  }

  Future<String> start({int? playlist}) async {
    try {
      onStage?.call('正在读取原盘目录与播放列表');
      record(
        '进入原盘读取：${kind == DiscKind.iso ? 'ISO/UDF' : 'BDMV'}；解析上限=120 秒；扇区缓存=8 MiB；${directInput ? '原生直读，无本机 HTTP 转发' : '播放 HTTP 缓存上限=${cacheBytes ~/ 1048576} MiB'}；连续单路独立预读；有序小块=64 KiB；队列上限=${cacheBytes * 3 ~/ 2 ~/ 1048576} MiB',
      );
      if (directInput) {
        base = 'yingyu-disc://$id';
      } else {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        if (_closed) {
          await server.close(force: true);
          throw const AppFailure('播放已退出');
        }
        _server = server;
        server.serverHeader = null;
        base = 'http://127.0.0.1:${server.port}/$id';
        server.listen((request) => unawaited(_serve(request)));
      }
      if (kind == DiscKind.blurayFolder) {
        final explicit = route.discFolderUrl;
        if (explicit != null) {
          _folder = discFolderRoot(explicit);
        } else {
          // Resolve the actual Emby/STRM redirect, never derive remote files
          // from the server's local Path (e.g. /mnt or drive letters).
          final opened = await _request(source, range: 'bytes=0-0');
          try {
            if (discAddressKind(opened.address) != DiscKind.blurayFolder) {
              throw const AppFailure(
                'Emby 没有提供可读取的 BDMV HTTP 目录；服务器本地路径不能在安卓直接打开',
              );
            }
            _folder = discFolderRoot(opened.address);
          } finally {
            opened.close();
          }
        }
      }
      if (_closed) throw const AppFailure('播放已退出');
      final data = await _native<String>('open', {
        'base': base,
        'iso': kind == DiscKind.iso,
      }).timeout(const Duration(seconds: 125));
      if (_closed) throw const AppFailure('播放已退出');
      titles = readableDiscTitles(
        jsonDecode(data ?? '[]'),
        onRejected: (count) => record('原盘跳过 $count 个无效播放列表；其他有效标题继续参与主片选择'),
      );
      if (titles.isEmpty) throw const AppFailure('原盘没有可播放的标题');
      selected = playlist == null
          ? titles.firstWhere(
              (title) => title.mainFeature,
              orElse: () => titles.first,
            )
          : titles.firstWhere(
              (t) => t.playlist == playlist,
              orElse: () => throw const AppFailure('所选原盘播放列表不存在'),
            );
      _clipIds.addAll(selected!.clips.map((c) => c.id));
      // Optional metadata probes may fail on an otherwise readable disc.
      // Preserve them in the log, but don't attach a stale probe to a later error.
      failure = null;
      record(
        '原盘解析完成：${titles.length} 个播放列表；选用 ${selected!.playlist}；片段=${selected!.clips.length}；时长=${selected!.duration ~/ 90000} 秒；仅解析第一个角度',
      );
      record(
        '原盘片段布局：独立文件=${_clipIds.length}；前 8 段=${selected!.clips.take(8).map((c) => "${c.id}:${c.start}-${c.end}").join(",")}（90 kHz）',
      );
      onStage?.call('原盘已解析，正在等待视频首帧');
      if (directInput) {
        await _native<void>('select', {'clips': _clipIds.toList()});
        final indexing = Stopwatch()..start();
        try {
          final value = await _native<String>('selectIndex', {
            'playlist': selected!.playlist,
          });
          if (!_closed) seekIndex = discSeekIndex(id, value ?? '[]', _clipIds);
        } catch (_) {
          // Missing or unsupported CLPI retains the existing timestamp search.
          seekIndex = '';
        }
        record(
          '原盘定位索引：${seekIndex.isEmpty ? '不可用，沿用精确搜索' : '已读取 CLPI 访问点，保留精确解码'}；准备=${indexing.elapsedMilliseconds} ms',
        );
        if (_closed) throw const AppFailure('播放已退出');
        record(
          '原盘输出=原生 MPV stream callback；输入=独立读取线程直接交付；本机 HTTP 转发=0；Java 媒体数组=0；保留原分段时间线',
        );
        return selected!.edl(base);
      }
      if (backgroundOutput) {
        final output = await _native<String>('output', {
          'clips': _clipIds.toList(),
        });
        if (_closed) throw const AppFailure('播放已退出');
        final uri = Uri.tryParse(output ?? '');
        if (uri == null ||
            uri.scheme != 'http' ||
            uri.host != '127.0.0.1' ||
            !uri.hasPort ||
            uri.userInfo.isNotEmpty ||
            uri.path != '/$id' ||
            uri.hasQuery ||
            uri.hasFragment) {
          throw const AppFailure('原盘后台输出入口无效');
        }
        record('原盘片段改由后台直接输出；媒体字节不再经 Flutter 平台通道返回；上游认证与文件校验保持');
        _outputTimer = Timer.periodic(
          const Duration(seconds: 3),
          (_) => unawaited(_pollOutput()),
        );
        return selected!.edl(output!);
      }
      return selected!.edl(base);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  /// The same validated network owner also serves the native callback reader.
  /// Only the IO isolate calls this; it does not bind a loopback HTTP server.
  Future<DiscRangeBlock?> readNativeInput(
    int operation,
    String relative,
    int start,
    int length,
    DiscReadCancellation cancellation,
  ) async {
    try {
      return await _readNativeInput(
        operation,
        relative,
        start,
        length,
        cancellation,
      );
    } catch (error) {
      // Native replies contain only a status code. Preserve the real sanitized
      // input failure here, including failures during directory parsing.
      if (!cancellation.cancelled && !_closed) _playbackFailed(error);
      rethrow;
    }
  }

  Future<DiscRangeBlock?> _readNativeInput(
    int operation,
    String relative,
    int start,
    int length,
    DiscReadCancellation cancellation,
  ) async {
    cancellation.check();
    if (_closed) throw const AppFailure('原盘读取已取消');
    if (!validDiscRelativePath(relative) ||
        !const {1, 2, 3}.contains(operation) ||
        (kind == DiscKind.iso && (relative.isNotEmpty || operation == 3)) ||
        start < 0 ||
        length < 0 ||
        length > 1048576) {
      throw const AppFailure('原盘底层请求无效');
    }
    final listing = operation == 3;
    if (!listing && length == 0) throw const AppFailure('原盘底层范围无效');
    if (operation == 2 && _sizes.containsKey(relative)) {
      return DiscRangeBlock(0, _sizes[relative]!, Uint8List(0));
    }
    if (!listing && selected != null) {
      final watch = Stopwatch()..start();
      try {
        final block = await _streamReader.read(
          relative,
          start,
          length,
          cancellation,
          availableOnly: operation == 1,
        );
        if (_sizes.containsKey(relative) && _sizes[relative] != block.total) {
          throw const DiscIdentityFailure();
        }
        _recordBody(block.bytes.length, watch);
        _sizes[relative] = block.total;
        return block;
      } catch (error) {
        if (!cancellation.cancelled) _playbackFailed(error);
        rethrow;
      } finally {
        _inputWaitMicroseconds += watch.elapsedMicroseconds;
      }
    }
    final target = kind == DiscKind.iso
        ? source
        : discChildAddress(_folder!, relative, directory: listing);
    final opened = await _request(
      target,
      range: listing ? null : 'bytes=$start-${start + length - 1}',
      cancellation: cancellation,
    );
    try {
      final response = opened.response;
      if (response.statusCode == 404) return null; // optional disc metadata
      if (response.statusCode != (listing ? 200 : 206)) {
        final body = await readDiagnosticBody(
          response,
          encoding: response.headers.value('content-encoding') ?? '',
        );
        final info = recordHttpFailure(
          log,
          log?.nextRequest('原盘') ?? '原盘',
          body,
          secrets: route.diagnosticSecrets,
        );
        throw AppFailure('原盘读取返回 HTTP ${response.statusCode}\n${info.summary}');
      }
      var total = 0, expected = 0;
      if (!listing) {
        final range = RegExp(
          r'^bytes (\d+)-(\d+)/(\d+)$',
        ).firstMatch(response.headers.value('content-range') ?? '');
        if (range == null) throw const AppFailure('原盘响应缺少有效 Content-Range');
        final begin = int.parse(range[1]!), end = int.parse(range[2]!);
        total = int.parse(range[3]!);
        if (begin != start ||
            end < start ||
            total <= end ||
            end != (start + length - 1).clamp(start, total - 1) ||
            !const {
              null,
              'identity',
            }.contains(response.headers.value('content-encoding'))) {
          throw const AppFailure('原盘响应的范围或编码与请求不匹配');
        }
        expected = end - begin + 1;
        if (response.contentLength >= 0 && response.contentLength != expected) {
          throw const AppFailure('原盘响应长度与范围不匹配');
        }
        if (_sizes.containsKey(relative) && _sizes[relative] != total) {
          throw const DiscIdentityFailure();
        }
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        cancellation.check();
        if (_closed) throw const AppFailure('原盘读取已取消');
        if (bytes.length + chunk.length > (listing ? 1048576 : expected)) {
          throw const AppFailure('原盘响应正文超过范围');
        }
        bytes.add(chunk);
      }
      if (!listing && bytes.length != expected) {
        throw const AppFailure('原盘响应正文提前结束');
      }
      cancellation.check();
      if (_closed) throw const AppFailure('播放已退出');
      opened.reusable = true;
      if (listing) {
        final entries = discDirectoryEntries(
          utf8.decode(bytes.takeBytes(), allowMalformed: true),
        );
        final result = utf8.encode(entries.join('\n'));
        if (result.length > 128 * 1024) throw const AppFailure('BDMV 目录条目过多');
        return entries.isEmpty
            ? null
            : DiscRangeBlock(0, 0, Uint8List.fromList(result));
      }
      _sizes[relative] = total;
      return DiscRangeBlock(start, total, bytes.takeBytes());
    } finally {
      opened.close();
    }
  }

  Future<_DiscResponse> _request(
    String address, {
    String? range,
    DiscReadCancellation? cancellation,
    DiscStreamIdentity? expectedIdentity,
  }) async {
    cancellation?.check();
    if (_closed) throw const AppFailure('原盘读取已取消');
    if (_targetFailures[address] case final failure?) throw failure;
    final pending = _resolvedTargets[address];
    final resolution = pending == null ? Completer<String>() : null;
    if (resolution != null) {
      _resolvedTargets[address] = resolution.future;
      unawaited(resolution.future.then<void>((_) {}, onError: (Object _) {}));
    }
    var target = pending == null ? address : await pending;
    cancellation?.check();
    if (expectedIdentity != null && target != expectedIdentity.address) {
      throw const DiscIdentityFailure();
    }
    if (_targetFailures[address] case final failure?) throw failure;
    final reusedClient = _idleClients.isNotEmpty;
    final client = _idleClients.isEmpty
        ? (HttpClient()
            ..autoUncompress = false
            ..connectionTimeout = const Duration(seconds: 30)
            ..idleTimeout = const Duration(seconds: 15))
        : _idleClients.removeLast();
    if (_closed) {
      client.close(force: true);
      throw const AppFailure('原盘读取已取消');
    }
    _clients.add(client);
    if (cancellation != null) {
      cancellation.abort = () => client.close(force: true);
    }
    final watch = Stopwatch()..start();
    final visited = <String>{if (target != address) address};
    var stage = '建立连接';
    var destination = '媒体入口';
    try {
      for (var hop = 0; hop < 8; hop++) {
        if (_closed) throw const AppFailure('原盘读取已取消');
        cancellation?.check();
        if (!visited.add(target) || _redirectEntries.contains(target)) {
          throw const AppFailure('媒体重定向返回了已访问入口，已停止重复解析');
        }
        final uri = ExactHttpUri(target);
        final sameOrigin =
            route.serverBase != null && uri.origin == route.serverBase!.origin;
        stage = '建立连接';
        destination = sameOrigin ? 'Emby 同源' : '外部媒体服务';
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        route.headers.forEach(request.headers.set);
        if (sameOrigin) route.sameOriginHeaders.forEach(request.headers.set);
        request.headers.set('Accept-Encoding', 'identity');
        if (range != null) request.headers.set('Range', range);
        if (expectedIdentity != null) {
          request.headers.set('If-Match', expectedIdentity.tag);
        }
        // close() submits the request and awaits the response. This boundary
        // does not independently acknowledge that every request byte was sent.
        stage = '提交请求并等待响应头';
        if (selected == null) {
          record(
            '原盘请求已就绪：跳数=${hop + 1}；目标=$destination；GET；'
            '${range ?? '目录'}；连接就绪累计=${watch.elapsedMilliseconds} ms；'
            '同源账户头=${sameOrigin && route.sameOriginHeaders.isNotEmpty ? '有' : '无'}；'
            '等待响应头上限=30 秒；HTTP客户端=${reusedClient ? '复用' : '新建'}；'
            '本阶段包含请求提交，发送完成未独立确认',
          );
        }
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        final location = response.headers.value('location');
        final now = DateTime.now().millisecondsSinceEpoch;
        _readCount++;
        if (selected == null ||
            response.statusCode >= 300 ||
            watch.elapsedMilliseconds > 5000 ||
            now - _lastReadLog >= 5000) {
          _lastReadLog = now;
          record(
            '原盘响应头：累计=$_readCount 次；跳数=${hop + 1}；${sameOrigin ? 'Emby 同源' : '媒体服务'}；HTTP ${response.statusCode}；${range ?? '目录'}；响应头耗时=${watch.elapsedMilliseconds} ms；同源账户头=${sameOrigin && route.sameOriginHeaders.isNotEmpty ? '有' : '无'}',
          );
        }
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode) &&
            location != null) {
          if (expectedIdentity != null) throw const DiscIdentityFailure();
          _redirectEntries.add(target);
          target = uri.resolve(location).toString();
          await response.listen((_) {}).cancel();
          continue;
        }
        if (const {401, 403, 408, 410, 429}.contains(response.statusCode) ||
            response.statusCode >= 500) {
          _targetFailures[address] = AppFailure(
            '媒体返回 HTTP ${response.statusCode}，已停止自动重试；不会重新访问 STRM 入口',
          );
        }
        if (resolution != null) {
          resolution.complete(target);
          record('原盘地址解析完成；本次播放复用该目标，失效后不自动重新解析');
        } else {
          _resolvedTargets[address] = Future.value(target);
        }
        return _DiscResponse(response, target, (reusable) {
          if (cancellation != null) cancellation.abort = null;
          _clients.remove(client);
          if (reusable && !_closed && _idleClients.length < 2) {
            _idleClients.add(client);
          } else {
            client.close(force: true);
          }
        });
      }
      throw const AppFailure('原盘重定向次数过多');
    } catch (error, stack) {
      final failure = error is TimeoutException
          ? AppFailure('原盘取流超时：$stage（30 秒）；目标=$destination；尚未收到本次上游 HTTP 响应')
          : error;
      if (!_closed && error is TimeoutException) {
        record('$failure；耗时=${watch.elapsedMilliseconds} ms', error: true);
        _targetFailures[address] = failure as AppFailure;
      }
      if (resolution != null && !resolution.isCompleted) {
        resolution.completeError(failure, stack);
      }
      if (cancellation != null) cancellation.abort = null;
      client.close(force: true);
      _clients.remove(client);
      Error.throwWithStackTrace(failure, stack);
    }
  }

  Future<DiscRangeBlock> _fetchBlock(
    String relative,
    int start,
    int length,
    DiscReadCancellation cancellation,
  ) async {
    final watch = Stopwatch()..start();
    if (persistentCache != null) {
      if (relative != _persistentActive) {
        for (final entry in _persistentReaders.entries) {
          if (entry.key != relative) entry.value.stopWarming();
        }
        _persistentActive = relative;
      }
      final reader = _persistentReaders.putIfAbsent(
        relative,
        () => CachedMediaReader(
          open: (_, offset, token) => _openStream(relative, offset, token),
          cache: persistentCache!,
          scope: playbackCacheHash([cacheScope, kind.name, relative]),
        ),
      );
      final bytes = await reader.read(start, length, cancellation);
      _updatePersistent(relative, reader);
      _recordBody(bytes.length, watch);
      return DiscRangeBlock(start, reader.total, bytes);
    }
    final block = await _streamReader.read(
      relative,
      start,
      length,
      cancellation,
    );
    _recordBody(block.bytes.length, watch);
    return block;
  }

  Future<DiscRangeBlock> _fetchProgressiveBlock(
    String relative,
    int start,
    int length,
    DiscReadCancellation cancellation,
    DiscReadProgress progress,
  ) async {
    final watch = Stopwatch()..start();
    final block = await _streamReader.read(
      relative,
      start,
      length,
      cancellation,
      onProgress: progress,
    );
    _recordBody(block.bytes.length, watch);
    return block;
  }

  Future<DiscStreamSource> _openStream(
    String relative,
    int start,
    DiscReadCancellation cancellation,
  ) async {
    final source = await _openRange(
      relative,
      start,
      null,
      persistentCache == null ? _orderedIdentities[relative] : null,
      cancellation,
    );
    if (persistentCache == null && source.identity != null) {
      _orderedIdentities[relative] = source.identity!;
    }
    return source;
  }

  Future<DiscStreamSource> _openRange(
    String relative,
    int start,
    int? requestedEnd,
    DiscStreamIdentity? expected,
    DiscReadCancellation cancellation,
  ) async {
    final target = kind == DiscKind.iso
        ? source
        : discChildAddress(_folder!, relative);
    final opened = await _request(
      target,
      range: 'bytes=$start-${requestedEnd ?? ''}',
      cancellation: cancellation,
      expectedIdentity: expected,
    );
    try {
      final upstream = opened.response;
      if (upstream.statusCode == 412 && expected != null) {
        throw const DiscIdentityFailure();
      }
      if (upstream.statusCode != 206) {
        final body = await readDiagnosticBody(
          upstream,
          encoding: upstream.headers.value('content-encoding') ?? '',
        );
        final info = recordHttpFailure(
          log,
          log?.nextRequest('原盘范围') ?? '原盘范围',
          body,
          secrets: route.diagnosticSecrets,
        );
        final error = AppFailure(
          '原盘随机读取需要 HTTP 206，实际为 HTTP ${upstream.statusCode}\n${info.summary}',
        );
        if (_targetFailures.containsKey(target)) {
          _targetFailures[target] = error;
        }
        throw error;
      }
      final match = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+)$',
      ).firstMatch(upstream.headers.value('content-range') ?? '');
      if (match == null) throw const AppFailure('原盘响应缺少有效 Content-Range');
      final begin = int.parse(match[1]!),
          end = int.parse(match[2]!),
          total = int.parse(match[3]!);
      if (begin != start ||
          end < start ||
          total <= end ||
          end != (requestedEnd ?? total - 1)) {
        if (expected != null) throw const DiscIdentityFailure();
        throw const AppFailure('媒体服务未返回完整的连续范围，已停止读取以避免反复分段请求');
      }
      if (!const {
        null,
        'identity',
      }.contains(upstream.headers.value('content-encoding'))) {
        throw const AppFailure('原盘范围响应包含压缩编码，无法按原文件字节定位');
      }
      final tag = upstream.headers.value('etag');
      final external =
          route.serverBase != null &&
          Uri.parse(opened.address).origin != route.serverBase!.origin;
      final identity =
          tag != null && RegExp(r'^"[\x21\x23-\x7E\x80-\xFF]*"$').hasMatch(tag)
          ? DiscStreamIdentity(opened.address, tag, total)
          : null;
      if (expected != null && !expected.matches(identity)) {
        throw const DiscIdentityFailure();
      }
      if (upstream.contentLength >= 0 &&
          upstream.contentLength != end - begin + 1) {
        throw const DiscIdentityFailure();
      }
      return DiscStreamSource(
        start: start,
        total: total,
        bytes: upstream,
        canResume: external,
        identity: identity,
        validator:
            upstream.headers.value('etag') ??
            upstream.headers.value('last-modified'),
        close: (fullyRead) {
          opened.reusable = fullyRead && requestedEnd != null;
          opened.close();
        },
      );
    } catch (_) {
      opened.close();
      rethrow;
    }
  }

  Future<void> _serve(HttpRequest incoming) async {
    final response = incoming.response;
    var disconnected = false, servingClip = false, writingInput = false;
    _ClipTransfer? transfer;
    unawaited(
      response.done.then(
        (_) => disconnected = true,
        onError: (Object _) => disconnected = true,
      ),
    );
    try {
      final path = incoming.uri.path;
      if (_closed ||
          !path.startsWith('/$id/') ||
          !const {'GET', 'HEAD'}.contains(incoming.method)) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      if (path == '/$id/input' || path == '/$id/list') {
        final relative = incoming.uri.queryParameters['path'] ?? '';
        if (!validDiscRelativePath(relative)) {
          throw const AppFailure('原盘内部路径无效');
        }
        final listing = path.endsWith('/list');
        final requestedRange = incoming.headers.value('range');
        final span = requestedRange == null
            ? null
            : RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(requestedRange);
        if (!listing &&
            (span == null ||
                int.parse(span[2]!) < int.parse(span[1]!) ||
                int.parse(span[2]!) - int.parse(span[1]!) >= 1024 * 1024)) {
          throw const AppFailure('原盘底层请求必须是最多 1 MiB 的有效字节范围');
        }
        final target = kind == DiscKind.iso
            ? source
            : discChildAddress(_folder!, relative, directory: listing);
        if (kind == DiscKind.iso && (relative.isNotEmpty || listing)) {
          throw const AppFailure('ISO 读取路径无效');
        }
        if (!listing && selected != null) {
          final start = int.parse(span![1]!), end = int.parse(span[2]!);
          final inputSequence = ++_inputSequence;
          final inputWatch = Stopwatch()..start();
          late final DiscRangeBlock block;
          try {
            block = await _rangeCache.read(relative, start, end - start + 1);
          } finally {
            _inputWaitMicroseconds += inputWatch.elapsedMicroseconds;
          }
          if (inputSequence <= 64) {
            record(
              '原盘底层#$inputSequence：范围=$start-$end；等待=${inputWatch.elapsedMilliseconds} ms；片段读者=${_activeClips.values.map((t) => "${t.number}:${t.clip}@${t.offset}").join(",")}',
            );
          }
          response.statusCode = 206;
          response.headers.set(
            'Content-Range',
            'bytes $start-${start + block.bytes.length - 1}/${block.total}',
          );
          response.contentLength = block.bytes.length;
          final writeWatch = Stopwatch()..start();
          try {
            writingInput = true;
            response.add(block.bytes);
            await response.close();
          } finally {
            _inputWriteMicroseconds += writeWatch.elapsedMicroseconds;
          }
          return;
        }
        final bodyWatch = Stopwatch()..start();
        final opened = await _request(
          target,
          range: listing ? null : incoming.headers.value('range'),
        );
        try {
          final upstream = opened.response;
          if (upstream.statusCode >= 400) {
            if (upstream.statusCode != 404) {
              final body = await readDiagnosticBody(
                upstream,
                encoding: upstream.headers.value('content-encoding') ?? '',
              );
              final info = recordHttpFailure(
                log,
                log?.nextRequest('原盘') ?? '原盘',
                body,
                secrets: route.diagnosticSecrets,
              );
              failure = '原盘读取返回 HTTP ${upstream.statusCode}\n${info.summary}';
              if (_targetFailures.containsKey(target)) {
                _targetFailures[target] = AppFailure(failure!);
              }
            }
            response.statusCode = upstream.statusCode;
            await response.close();
            return;
          }
          if (listing) {
            final bytes = BytesBuilder(copy: false);
            await for (final data in upstream.timeout(
              const Duration(seconds: 30),
            )) {
              if (bytes.length + data.length > 1024 * 1024) {
                throw const AppFailure('BDMV 目录响应超过 1 MiB 限制');
              }
              bytes.add(data);
            }
            opened.reusable = true;
            final entries = discDirectoryEntries(
              utf8.decode(bytes.takeBytes(), allowMalformed: true),
            );
            if (entries.isEmpty) {
              response.statusCode = 404;
            } else {
              response.write(entries.join('\n'));
            }
            await response.close();
          } else {
            final contentRange = RegExp(
              r'^bytes (\d+)-(\d+)/(\d+)$',
            ).firstMatch(upstream.headers.value('content-range') ?? '');
            if (upstream.statusCode != 206) {
              throw AppFailure(
                '原盘随机读取需要 HTTP 206，实际为 HTTP ${upstream.statusCode}',
              );
            }
            if (contentRange == null ||
                contentRange[1] != span![1] ||
                int.parse(contentRange[2]!) > int.parse(span[2]!) ||
                int.parse(contentRange[2]!) < int.parse(contentRange[1]!) ||
                int.parse(contentRange[3]!) <= int.parse(contentRange[2]!)) {
              throw const AppFailure('原盘响应的 Content-Range 与请求不匹配');
            }
            if (!const {
              null,
              'identity',
            }.contains(upstream.headers.value('content-encoding'))) {
              throw const AppFailure('原盘范围响应包含压缩编码，无法按原文件字节定位');
            }
            response.statusCode = upstream.statusCode;
            for (final header in [
              'content-range',
              'content-length',
              'content-type',
              'content-encoding',
            ]) {
              final value = upstream.headers.value(header);
              if (value != null) response.headers.set(header, value);
            }
            var received = 0;
            await response.addStream(
              upstream.timeout(const Duration(seconds: 30)).map((bytes) {
                received += bytes.length;
                return bytes;
              }),
            );
            _recordBody(received, bodyWatch);
            opened.reusable = true;
            await response.close();
          }
        } finally {
          opened.close();
        }
        return;
      }
      final clip = RegExp('^/$id/clip/([0-9]{5})\\.m2ts\$').firstMatch(path);
      if (clip == null || !_clipIds.contains(clip[1])) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      servingClip = true;
      final file = 'BDMV/STREAM/${clip[1]}.m2ts';
      int size;
      try {
        size = _sizes[file] ??=
            (await _native<int>('size', {'path': file})) ?? 0;
      } catch (error) {
        if (!disconnected) _playbackFailed(error);
        rethrow;
      }
      final range = discByteRange(incoming.headers.value('range'), size);
      if (range == null) {
        response.statusCode = 416;
        response.headers.set('Content-Range', 'bytes */$size');
        await response.close();
        return;
      }
      if (incoming.method == 'GET') {
        for (final old in _activeClips.values.toList()) {
          if (old.clip == clip[1] && !old.cancelled) old.cancel();
        }
      }
      transfer = _ClipTransfer(
        ++_clipSequence,
        clip[1]!,
        range.start,
        response,
      );
      _activeClips[transfer.number] = transfer;
      record(
        '原盘片段#${transfer.number} 开始：文件=${transfer.clip}；${incoming.method}；范围=${range.start}-${range.end}；总长=$size；活动请求=${_activeClips.length}',
      );
      response.statusCode = incoming.headers.value('range') == null ? 200 : 206;
      response.contentLength = range.end - range.start + 1;
      response.headers.set('Accept-Ranges', 'bytes');
      response.headers.set('Content-Type', 'video/mp2t');
      if (response.statusCode == 206) {
        response.headers.set(
          'Content-Range',
          'bytes ${range.start}-${range.end}/$size',
        );
      }
      if (incoming.method != 'HEAD') {
        for (
          var offset = range.start;
          offset <= range.end &&
              !_closed &&
              !disconnected &&
              !transfer.cancelled;
        ) {
          final length = (range.end - offset + 1).clamp(1, _transferBytes);
          Uint8List? bytes;
          final nativeWatch = Stopwatch()..start();
          transfer.offset = offset;
          try {
            bytes = await _native<Uint8List>('read', {
              'path': file,
              'offset': offset,
              'length': length,
            });
            if (!_closed &&
                !disconnected &&
                !transfer.cancelled &&
                (bytes == null || bytes.length != length)) {
              throw AppFailure(failure ?? '原盘片段提前结束');
            }
          } catch (error) {
            if (!_closed && !disconnected && !transfer.cancelled) {
              _playbackFailed(error);
            }
            rethrow;
          } finally {
            transfer.nativeMilliseconds += nativeWatch.elapsedMilliseconds;
          }
          if (_closed || disconnected || transfer.cancelled) break;
          final flushWatch = Stopwatch()..start();
          response.add(bytes!);
          await response.flush();
          transfer.flushMilliseconds += flushWatch.elapsedMilliseconds;
          transfer.bytes += bytes.length;
          offset += bytes.length;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastClipLog >= 5000) {
            _lastClipLog = now;
            record(
              '原盘片段传输：活动=${_activeClips.length}；${_activeClips.values.take(6).map((t) => t.summary).join("；")}',
            );
          }
        }
      }
      await response.close();
    } catch (error) {
      if (!_closed &&
          transfer?.cancelled != true &&
          !((servingClip || writingInput) &&
              (disconnected ||
                  error is SocketException ||
                  error is HttpException))) {
        final message = redactLog(
          safeError(error),
          secrets: route.diagnosticSecrets,
        );
        if (message != failure) {
          failure = message;
          record('原盘读取失败：$failure', error: true);
        }
      }
      try {
        response.statusCode = 502;
        await response.close();
      } catch (_) {
        /* reader disconnected */
      }
    } finally {
      if (transfer != null) {
        _activeClips.remove(transfer.number);
        record(
          '原盘片段结束：${transfer.summary}；已退出=$_closed；范围被替换=${transfer.cancelled}；连接结束=$disconnected；活动=${_activeClips.length}',
        );
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _outputTimer?.cancel();
    for (final reader in _persistentReaders.values) {
      await reader.close();
    }
    _persistentReaders.clear();
    _rangeCache.close();
    await _streamReader.close();
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
    for (final client in _idleClients) {
      client.close(force: true);
    }
    _idleClients.clear();
    await _server?.close(force: true);
    try {
      await _native<void>('close').timeout(const Duration(seconds: 5));
    } catch (_) {
      /* native cancellation remains queued */
    }
  }
}

class _ClipTransfer {
  _ClipTransfer(this.number, this.clip, this.offset, this.response);
  final int number;
  final String clip;
  final HttpResponse response;
  bool cancelled = false;
  void cancel() {
    cancelled = true;
    // HttpResponse.done alone can remain pending while a decoder abandons a
    // range. Expire only the superseded response, including a blocked flush.
    response.deadline = Duration.zero;
  }

  final watch = Stopwatch()..start();
  int offset, bytes = 0, nativeMilliseconds = 0, flushMilliseconds = 0;
  String get summary =>
      '#$number/$clip@$offset：已送=${(bytes / 1048576).toStringAsFixed(2)} MiB，原盘调用=$nativeMilliseconds ms，写出=$flushMilliseconds ms，存活=${watch.elapsedMilliseconds} ms';
}

class _DiscResponse {
  _DiscResponse(this.response, this.address, this.onClose);
  final HttpClientResponse response;
  final String address;
  final void Function(bool) onClose;
  bool reusable = false, _closed = false;
  void close() {
    if (_closed) return;
    _closed = true;
    // Only a fully drained response can return its TCP/TLS connection to the
    // bounded pool. Aborted, invalid or partly inspected replies are closed.
    onClose(reusable);
  }
}

bool validDiscRelativePath(String path) =>
    path.isEmpty ||
    (RegExp(
          r'^(?:BDMV|AACS|BDSVM|CERTIFICATE)(?:/[A-Za-z0-9_.-]+)*$',
        ).hasMatch(path) &&
        !path.split('/').any((part) => part == '.' || part == '..'));

String discFolderRoot(String address) {
  final uri = ExactHttpUri(address);
  final match = RegExp(
    r'/BDMV(?:/|$)',
    caseSensitive: false,
  ).firstMatch(uri.path);
  final path = match == null
      ? (uri.path.endsWith('/') ? uri.path : '${uri.path}/')
      : uri.path.substring(0, match.start + 1);
  return '${uri.scheme}://${uri.authority}$path${uri.hasQuery ? '?${uri.query}' : ''}';
}

String discChildAddress(
  String root,
  String relative, {
  bool directory = false,
}) {
  if (!validDiscRelativePath(relative)) throw const AppFailure('原盘内部路径无效');
  final uri = ExactHttpUri(root);
  return '${uri.scheme}://${uri.authority}${uri.path}$relative${directory && relative.isNotEmpty ? '/' : ''}${uri.hasQuery ? '?${uri.query}' : ''}';
}

List<String> discDirectoryEntries(String html) {
  final entries = <String>{};
  for (final match in RegExp(
    r'''href\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).allMatches(html)) {
    final href = match[1]!.replaceAll('&amp;', '&');
    // Only immediate, ordinary filesystem names. No cross-host links, parent
    // traversal, signed URLs or script data are accepted as directory entries.
    final name = href.endsWith('/') ? href.substring(0, href.length - 1) : href;
    if (RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,254}$').hasMatch(name) &&
        name != '..') {
      entries.add(name);
    }
    if (entries.length > 4096) throw const AppFailure('原盘目录条目超过 4096 项');
  }
  return entries.toList();
}

// Test API only. The full production class above is unchanged except imports.
class DiscHeaderProbe extends DiscTransport {
  DiscHeaderProbe(super.route):super(kind:DiscKind.iso);
  Future<int> headerProbe(DiscReadCancellation token) async {
    final opened=await _request(source,range:'bytes=0-3',cancellation:token);
    try {return opened.response.statusCode;} finally {opened.close();}
  }
  void closeProbe() {
    _closed=true;
    for(final client in _clients.toList()){client.close(force:true);}
    for(final client in _idleClients){client.close(force:true);}
    _clients.clear();_idleClients.clear();
  }
}
