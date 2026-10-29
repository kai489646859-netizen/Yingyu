import 'dart:async';
import 'dart:typed_data';
import '../core/models.dart';

class DiscReadCancellation {
  bool cancelled = false;
  void Function()? abort;
  void check() {
    if (cancelled) throw const AppFailure('原盘预读已取消');
  }

  void cancel() {
    cancelled = true;
    abort?.call();
  }
}

class DiscRangeBlock {
  const DiscRangeBlock(this.start, this.total, this.bytes);
  final int start, total;
  final Uint8List bytes;
}

typedef DiscRangeFetch =
    Future<DiscRangeBlock> Function(
      String path,
      int start,
      int length,
      DiscReadCancellation cancellation,
    );

// Prefix views are read-only to the receiver. Bytes already published must
// never be rewritten; only the portion beyond the view may still be filled.
typedef DiscReadProgress = void Function(DiscRangeBlock prefix);
typedef DiscProgressiveFetch =
    Future<DiscRangeBlock> Function(
      String path,
      int start,
      int length,
      DiscReadCancellation cancellation,
      DiscReadProgress progress,
    );
typedef _Key = ({String path, int start});

class _ReadJob {
  _ReadJob(this.key, this.demand);
  final _Key key;
  bool demand;
  final cancellation = DiscReadCancellation();
  final result = Completer<DiscRangeBlock>();
  Completer<void> changed = Completer<void>();
  DiscRangeBlock? prefix;
  int waiters = 0;

  void pulse() {
    changed.complete();
    changed = Completer<void>();
  }

  void fail(Object error, [StackTrace? stack]) {
    if (!result.isCompleted) result.completeError(error, stack);
    pulse();
  }
}

/// Bounded block read-ahead, above the native reader's 1 MiB sector cache.
/// The fetcher may serve many local blocks from one continuous HTTP response.
/// Only completed, validated byte ranges are cached. Speculation cannot fail
/// playback: its errors are discarded and a subsequent demand retries normally.
class DiscRangeCache {
  DiscRangeCache(
    this.fetch, {
    this.maxBytes = 32 * 1024 * 1024,
    this.progressiveFetch,
  }) : assert(maxBytes >= 16 * 1024 * 1024);
  static const blockBytes = 4 * 1024 * 1024;
  final DiscRangeFetch fetch;
  final DiscProgressiveFetch? progressiveFetch;
  final int maxBytes;
  final _cache = <_Key, DiscRangeBlock>{};
  final _pending = <_Key, _ReadJob>{};
  final _queue = <_ReadJob>[];
  bool _closed = false;
  int _running = 0, cachedBytes = 0, hits = 0, misses = 0;
  int peakRequests = 0, waitingReads = 0, servedBytes = 0;
  int demandWaitMicroseconds = 0;
  int progressiveReturns = 0, copyMicroseconds = 0;
  int _ahead = 1;
  bool _sequential = false;
  String? _lastPath;
  int? _lastEnd, _lastTotal;
  _Key? _forwardRead;

  int get aheadBlocks => _ahead;
  int get activeRequests => _running;
  void setSpeed(double speed) {
    if (!speed.isFinite || speed <= 0) return;
    final capacity = maxBytes ~/ blockBytes - 1;
    _ahead = speed > 2 ? capacity : speed.ceil().clamp(1, 2).clamp(1, capacity);
    // Prime the larger window now, even when the native reader is resting on
    // its own cached data. A decrease lets contiguous work finish: aborting a
    // speculative block would also close the shared continuous HTTP response.
    if (!_closed && _sequential && _lastEnd != null && _lastEnd! > 0) {
      _prefetch(
        _lastPath!,
        (_lastEnd! - 1) ~/ blockBytes * blockBytes,
        _lastTotal!,
      );
    }
  }

  void resetReadAhead() {
    _lastPath = null;
    _lastEnd = null;
    _lastTotal = null;
    _sequential = false;
    _forwardRead = null;
    _cancelOutside(const {});
  }

  Future<DiscRangeBlock> read(String path, int start, int length) async {
    if (_closed) throw const AppFailure('原盘读取已取消');
    if (start < 0 || length <= 0 || length > 1024 * 1024) {
      throw const AppFailure('原盘缓存读取范围无效');
    }
    final first = start ~/ blockBytes * blockBytes;
    final sequential = path == _lastPath && start == _lastEnd;
    final keep = <_Key>{
      for (var n = 0; n <= _ahead; n++)
        (path: path, start: first + n * blockBytes),
    };
    if (!sequential) _cancelOutside(keep);
    final blocks = <DiscRangeBlock>[];
    var offset = start;
    var remaining = length;
    while (remaining > 0) {
      final key = (path: path, start: offset ~/ blockBytes * blockBytes);
      _forwardRead = sequential ? key : null;
      final waiting = !_cache.containsKey(key);
      final watch = waiting ? (Stopwatch()..start()) : null;
      if (waiting) waitingReads++;
      // Promote demand before queuing the next contiguous block. Production
      // serializes both jobs through one HTTP response in DiscStreamReader.
      final current = _get(
        key,
        (offset - key.start + remaining).clamp(0, blockBytes),
      );
      if (sequential && _lastTotal != null) {
        _prefetch(path, key.start, _lastTotal!);
      }
      late final DiscRangeBlock block;
      try {
        block = await current;
      } finally {
        if (watch != null) {
          watch.stop();
          waitingReads--;
          demandWaitMicroseconds += watch.elapsedMicroseconds;
        }
      }
      if (_closed) throw const AppFailure('原盘读取已取消');
      blocks.add(block);
      final available = (block.start + block.bytes.length - offset).clamp(
        0,
        remaining,
      );
      if (available == 0) throw const AppFailure('原盘响应不足以满足范围读取');
      offset += available;
      remaining -= available;
      if (offset >= block.total) break;
    }
    _lastPath = path;
    _lastEnd = offset;
    _lastTotal = blocks.first.total;
    _sequential = sequential;
    if (sequential) {
      final last = blocks.last;
      _prefetch(path, last.start, last.total);
    }
    final copyWatch = Stopwatch()..start();
    final result = Uint8List(length - remaining);
    var written = 0;
    for (final block in blocks) {
      final from = start + written - block.start;
      final count = (block.bytes.length - from).clamp(
        0,
        result.length - written,
      );
      result.setRange(written, written + count, block.bytes, from);
      written += count;
    }
    servedBytes += result.length;
    copyMicroseconds += copyWatch.elapsedMicroseconds;
    return DiscRangeBlock(start, blocks.first.total, result);
  }

  void _prefetch(String path, int start, int total) {
    for (var n = 1; n <= _ahead; n++) {
      final next = start + n * blockBytes;
      if (next >= total) break;
      final key = (path: path, start: next);
      if (!_cache.containsKey(key) && !_pending.containsKey(key)) {
        _enqueue(key, demand: false);
      }
    }
  }

  Future<DiscRangeBlock> _get(_Key key, int requiredBytes) {
    final cached = _cache.remove(key);
    if (cached != null) {
      hits++;
      _cache[key] = cached;
      return Future.value(cached);
    }
    misses++;
    final job = _pending[key];
    if (job != null) {
      job.demand = true;
      _pump();
      return _waitThrough(job, requiredBytes);
    }
    return _waitThrough(_enqueue(key, demand: true), requiredBytes);
  }

  Future<DiscRangeBlock> _waitThrough(_ReadJob job, int requiredBytes) async {
    job.waiters++;
    try {
      while (true) {
        job.cancellation.check();
        if (job.result.isCompleted) return await job.result.future;
        final prefix = job.prefix;
        if (prefix != null &&
            prefix.bytes.length >=
                requiredBytes.clamp(0, prefix.total - prefix.start)) {
          progressiveReturns++;
          return prefix;
        }
        await job.changed.future;
      }
    } finally {
      job.waiters--;
      // After an early delivery, the tail is speculation. A seek may cancel
      // it once no consumer still waits, even though the full block is pending.
      if (job.waiters == 0 && progressiveFetch != null) job.demand = false;
    }
  }

  void _publish(_ReadJob job, DiscRangeBlock prefix) {
    job.cancellation.check();
    if (_closed) throw const AppFailure('原盘读取已取消');
    final previous = job.prefix;
    if (prefix.start != job.key.start ||
        prefix.bytes.isEmpty ||
        prefix.total <= prefix.start ||
        prefix.bytes.length >
            (prefix.total - prefix.start).clamp(0, blockBytes) ||
        previous != null && prefix.total != previous.total) {
      throw const AppFailure('原盘渐进数据与已校验范围不一致');
    }
    // A bounded, identity-checked recovery can replay a prefix. Do not replace
    // a longer view already delivered to a consumer with a shorter replay.
    if (previous == null || prefix.bytes.length > previous.bytes.length) {
      job.prefix = prefix;
      job.pulse();
    }
  }

  _ReadJob _enqueue(_Key key, {required bool demand}) {
    final job = _ReadJob(key, demand);
    // Speculation and cancelled reads may have no remaining waiter.
    unawaited(job.result.future.then<void>((_) {}, onError: (Object _) {}));
    _pending[key] = job;
    _queue.add(job);
    _pump();
    return job;
  }

  void _pump() {
    while (!_closed && _running < 2 && _queue.isNotEmpty) {
      final index = _queue.indexWhere((job) => job.demand);
      final job = _queue.removeAt(index < 0 ? 0 : index);
      _running++;
      if (_running > peakRequests) peakRequests = _running;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_ReadJob job) async {
    try {
      final progressive = progressiveFetch;
      final block = await (progressive == null
          ? fetch(job.key.path, job.key.start, blockBytes, job.cancellation)
          : progressive(
              job.key.path,
              job.key.start,
              blockBytes,
              job.cancellation,
              (prefix) => _publish(job, prefix),
            ));
      job.cancellation.check();
      if (_closed) throw const AppFailure('原盘读取已取消');
      if (block.start != job.key.start ||
          job.prefix != null && block.total != job.prefix!.total ||
          block.bytes.isEmpty ||
          block.bytes.length !=
              (block.total - block.start).clamp(0, blockBytes)) {
        throw const AppFailure('原盘缓存块长度与资源范围不一致');
      }
      while (cachedBytes + block.bytes.length > maxBytes && _cache.isNotEmpty) {
        // Recently consumed bytes are newer in LRU than unread prefetch bytes.
        // On a full forward window reclaim those consumed bytes first. Keep
        // the normal cache intact while space remains and after explicit seeks.
        final forward = _forwardRead;
        final consumed = forward == null
            ? null
            : _cache.keys
                  .where(
                    (key) =>
                        key.path == forward.path && key.start < forward.start,
                  )
                  .firstOrNull;
        cachedBytes -= _cache
            .remove(consumed ?? _cache.keys.first)!
            .bytes
            .length;
      }
      _cache[job.key] = block;
      cachedBytes += block.bytes.length;
      job.result.complete(block);
      job.pulse();
    } catch (error, stack) {
      job.fail(error, stack);
    } finally {
      job.cancellation.abort = null;
      if (identical(_pending[job.key], job)) _pending.remove(job.key);
      _running--;
      _pump();
    }
  }

  void _cancelOutside(Set<_Key> keep) {
    for (final job in _pending.values.toList()) {
      if (job.demand || keep.contains(job.key)) continue;
      job.cancellation.cancel();
      _pending.remove(job.key);
      if (_queue.remove(job) && !job.result.isCompleted) {
        job.fail(const AppFailure('原盘预读已取消'));
      }
    }
  }

  void close() {
    _closed = true;
    for (final job in _pending.values) {
      job.cancellation.cancel();
      if (!job.result.isCompleted) {
        job.fail(const AppFailure('原盘读取已取消'));
      }
    }
    _queue.clear();
    _pending.clear();
    _cache.clear();
    cachedBytes = 0;
  }
}
