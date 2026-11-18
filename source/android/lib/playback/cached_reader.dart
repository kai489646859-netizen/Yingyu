import 'dart:async';
import 'dart:math' as math;
import 'dart:io' show HttpDate;
import 'dart:typed_data';
import '../core/models.dart';
import 'byte_cache.dart';
import 'cache_policy.dart';
import 'disc_cache.dart';
import 'disc_stream.dart';

/// One continuous remote response. Background reads yield to a new demand,
/// and neither a seek nor startup waits for the read-ahead window to fill.
class CachedMediaReader {
  CachedMediaReader({
    required this.open,
    required this.cache,
    required this.scope,
    this.deferDiskUntilPlayback = false,
  }) : _diskActivated = !deferDiskUntilPlayback;
  final DiscStreamOpen open;
  final PlaybackByteCache cache;
  final String scope;
  final bool deferDiskUntilPlayback;
  bool _diskActivated;
  Future<void>? _foregroundWrite;
  static const blockBytes = playbackCacheBlockBytes;
  late final _reader = DiscStreamReader(_open);
  DiscStreamSource? _seed;
  Future<void>? _initializing;
  String? _identity, _validator;
  int total = 0, aheadBytes = 0, cursor = 0, _epoch = 0;
  int _warmedUntil = 0;
  bool _closed = false,
      _warming = false,
      _enabled = false,
      _speculationFailed = false;
  DiscReadCancellation? _active;
  int? _activeStart;
  Future<DiscRangeBlock>? _activeJob;
  bool _activeSpeculative = false;
  DiscReadCancellation? _activeOwner;
  final _hot = <int, DiscRangeBlock>{};

  Future<DiscStreamSource> _open(
    String path,
    int start,
    DiscReadCancellation cancellation,
  ) async {
    final seed = _seed;
    if (seed != null && seed.start == start) {
      _seed = null;
      return seed;
    }
    _seed?.close(false);
    _seed = null;
    final response = await open(path, start, cancellation);
    if (total != 0 &&
        (total != response.total || _validator != response.validator)) {
      response.close(false);
      throw const AppFailure('视频文件已发生变化，请重新打开，旧缓存不会混入');
    }
    return response;
  }

  Future<void> initialize(int start, DiscReadCancellation cancellation) =>
      _initializing ??= () async {
        final source = await open(
          '',
          start ~/ blockBytes * blockBytes,
          cancellation,
        );
        if (_closed || cancellation.cancelled) {
          source.close(false);
          cancellation.check();
          throw const AppFailure('播放已退出');
        }
        total = source.total;
        _validator = source.validator;
        _seed = source;
        // The reader now owns this response. A completed HEAD/small local GET
        // must not close the remote stream while the next range consumes it.
        cancellation.abort = null;
        // An unvalidated response must never resurrect another session's bytes.
        if (_reusable(_validator)) {
          _identity = playbackCacheHash([scope, _validator, total]);
        }
      }();

  static bool _reusable(String? validator) {
    if (validator == null || validator.startsWith('W/')) return false;
    if (validator.startsWith('etag:"') ||
        validator.startsWith('"') ||
        validator.startsWith('modified:')) {
      return true;
    }
    try {
      HttpDate.parse(validator);
      return true;
    } catch (_) {
      return false;
    }
  }

  void configureAhead(int bytes) {
    final wasEnabled = _enabled;
    _diskActivated = true;
    aheadBytes = bytes;
    _enabled = true;
    if (!wasEnabled) _speculationFailed = false;
    _warm();
  }

  int get _aheadEnd {
    final limit = cache.limitBytes;
    final capacity = limit < 0
        ? aheadBytes
        : limit ~/ (blockBytes + playbackCacheHeaderBytes) * blockBytes;
    return math.min(total, cursor + math.min(aheadBytes, capacity));
  }

  void suspend() {
    _warmedUntil = 0;
    _enabled = false;
    _epoch++;
    _active?.cancel();
    _seed?.close(false);
    _seed = null;
    if (_identity != null) cache.release(_identity);
  }

  void stopWarming() {
    _warmedUntil = 0;
    _enabled = false;
    _epoch++;
    if (_activeSpeculative) _active?.cancel();
    if (_identity != null) cache.release(_identity);
  }

  Future<DiscRangeBlock> _block(
    int start, {
    bool speculative = false,
    DiscReadCancellation? owner,
  }) async {
    if (_closed) throw const AppFailure('播放已退出');
    final identity = _diskActivated ? _identity : null;
    if (_hot[start] case final hit?) {
      if (!deferDiskUntilPlayback &&
          speculative &&
          identity != null &&
          !cache.contains(identity, start)) {
        await _save(identity, start, hit.bytes);
      }
      return hit;
    }
    final size = math.min(blockBytes, total - start);
    if (identity != null &&
        (!deferDiskUntilPlayback || cache.contains(identity, start))) {
      final bytes = await cache.read(identity, start, size);
      if (bytes != null) {
        _seed?.close(false);
        _seed = null;
        return DiscRangeBlock(start, total, bytes);
      }
    }
    if (_activeStart == start &&
        _activeJob != null &&
        _active?.cancelled == false) {
      if (!speculative) _activeSpeculative = false;
      if (owner != null) {
        _activeOwner = owner;
        final joined = _activeJob;
        owner.abort = () {
          if (identical(_activeOwner, owner) && identical(_activeJob, joined)) {
            _active?.cancel();
          }
        };
      }
      return _activeJob!;
    }
    if (_activeJob != null) {
      if (!speculative && _activeSpeculative) _active?.cancel();
      try {
        await _activeJob;
      } catch (_) {}
      return _block(start, speculative: speculative, owner: owner);
    }
    final cancellation = DiscReadCancellation();
    _active = cancellation;
    _activeSpeculative = speculative;
    _activeStart = start;
    final job = _activeJob = () async {
      final result = await _reader.read('', start, size, cancellation);
      cancellation.check();
      if (!_closed) {
        _hot[start] = result;
        while (_hot.length > 4) {
          _hot.remove(_hot.keys.first);
        }
        if (identity != null) {
          if (!deferDiskUntilPlayback) {
            await _save(identity, start, result.bytes);
          } else if (!speculative && _enabled && _foregroundWrite == null) {
            // Keep at most one pending demand write. Read-ahead owns the next
            // uncached block if storage cannot keep up with playback.
            final write = _foregroundWrite = _save(
              identity,
              start,
              result.bytes,
            ).whenComplete(() => _foregroundWrite = null);
            unawaited(write);
          }
        }
      }
      return result;
    }();
    _activeOwner = owner;
    owner?.abort = () {
      if (identical(_activeOwner, owner) && identical(_activeJob, job)) {
        cancellation.cancel();
      }
    };
    try {
      return await job;
    } finally {
      owner?.abort = null;
      if (identical(_activeJob, job)) {
        _activeJob = null;
        _active = null;
        _activeStart = null;
      }
    }
  }

  Future<void> _save(String identity, int start, Uint8List bytes) async {
    try {
      await cache.write(identity, start, bytes);
    } catch (_) {
      cache.warning = '播放缓存暂不可写，继续直接播放';
    }
  }

  Future<Uint8List> read(
    int start,
    int length,
    DiscReadCancellation cancellation,
  ) async {
    cancellation.check();
    await initialize(start, cancellation);
    cancellation.check();
    if (start < 0 || start >= total || length <= 0) {
      throw const AppFailure('视频读取范围无效');
    }
    final first = start ~/ blockBytes * blockBytes;
    // A far-away index read/seek cancels old speculation immediately.
    if ((first - cursor).abs() > blockBytes * 4) {
      _epoch++;
      _warmedUntil = first;
      _speculationFailed = false;
      if (_activeSpeculative) _active?.cancel();
    }
    cursor = first;
    final out = BytesBuilder(copy: false);
    var at = start, left = math.min(length, total - start);
    while (left > 0) {
      cancellation.check();
      final aligned = at ~/ blockBytes * blockBytes;
      final block = await _block(aligned, owner: cancellation);
      cancellation.check();
      final from = at - aligned,
          take = math.min(left, block.bytes.length - from);
      out.add(Uint8List.sublistView(block.bytes, from, from + take));
      at += take;
      left -= take;
    }
    cursor = at ~/ blockBytes * blockBytes;
    _protect();
    _warm();
    return out.takeBytes();
  }

  void _protect() {
    final identity = _identity;
    if (identity == null || !_enabled) return;
    cache.protectRange(identity, cursor, _aheadEnd);
  }

  void _warm() {
    if (_warming ||
        !_enabled ||
        !cache.ready ||
        cache.limitBytes == 0 ||
        _closed ||
        _identity == null ||
        _speculationFailed ||
        aheadBytes <= 0 ||
        total <= 0) {
      return;
    }
    _warming = true;
    final epoch = _epoch;
    unawaited(() async {
      try {
        var at = math.max(cursor, _warmedUntil), cachedBlocks = 0;
        _protect();
        while (!_closed && _enabled && epoch == _epoch && at < _aheadEnd) {
          if (at < cursor) at = cursor;
          if (!cache.contains(_identity!, at)) {
            final block = await _block(at, speculative: true);
            if (_closed || !_enabled || epoch != _epoch) break;
            if (deferDiskUntilPlayback && !cache.contains(_identity!, at)) {
              await _save(_identity!, at, block.bytes);
            }
            cachedBlocks = 0;
          } else if (++cachedBlocks == 64) {
            // Network and disk reads already yield. Only a scan of cached
            // offsets needs to give the event loop an opportunity to run.
            cachedBlocks = 0;
            await Future<void>.delayed(Duration.zero);
          }
          if (cache.warning != null || !cache.contains(_identity!, at)) break;
          at += blockBytes;
          if (epoch == _epoch) _warmedUntil = at;
        }
      } catch (_) {
        if (epoch == _epoch && !_closed) _speculationFailed = true;
      } finally {
        _warming = false;
        // A newer cursor owns the next job. Never retry a failed HTTP request.
        if (epoch != _epoch && !_closed) _warm();
      }
    }());
  }

  Future<void> close() async {
    _closed = true;
    suspend();
    await _reader.close();
    await _foregroundWrite;
    if (_identity != null) cache.release(_identity);
  }
}
