import 'dart:async';
import 'dart:math' as math;
import 'dart:io' show HttpDate;
import 'dart:typed_data';
import '../core/models.dart';
import 'byte_cache.dart';
import 'disc_cache.dart';
import 'disc_stream.dart';

/// One continuous remote response. Background reads yield to a new demand,
/// and neither a seek nor startup waits for the read-ahead window to fill.
class CachedMediaReader {
  CachedMediaReader({
    required this.open,
    required this.cache,
    required this.scope,
  });
  final DiscStreamOpen open;
  final PlaybackByteCache cache;
  final String scope;
  static const blockBytes = 256 * 1024;
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
    aheadBytes = cache.limitBytes > 0
        ? math.min(bytes, (cache.limitBytes * .9).floor())
        : bytes;
    _enabled = true;
    _speculationFailed = false;
    _warm();
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
    if (_hot[start] case final hit?) return hit;
    final identity = _identity;
    final size = math.min(blockBytes, total - start);
    if (identity != null) {
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
          try {
            await cache.write(identity, start, result.bytes);
          } catch (_) {
            cache.warning = '播放缓存暂不可写，继续直接播放';
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
    if (identity == null) return;
    final end = math.min(total, cursor + aheadBytes);
    cache.protectRange(identity, cursor, end);
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
        var at = math.max(cursor, _warmedUntil);
        _protect();
        while (!_closed &&
            _enabled &&
            epoch == _epoch &&
            at < math.min(total, cursor + aheadBytes)) {
          if (!cache.contains(_identity!, at)) {
            await _block(at, speculative: true);
          }
          if (cache.warning != null) break;
          at += blockBytes;
          if (epoch == _epoch) _warmedUntil = at;
          // Let an incoming demand or seek run before the next speculative read.
          await Future<void>.delayed(Duration.zero);
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
    if (_identity != null) cache.release(_identity);
  }
}
