import 'dart:async';
import 'dart:io' show HttpException, SocketException;
import 'dart:typed_data';
import '../core/models.dart';
import 'disc_cache.dart';
import 'disc_stream.dart';

typedef DiscPartOpen =
    Future<DiscStreamSource> Function(
      String path,
      int start,
      int end,
      DiscStreamIdentity identity,
      DiscReadCancellation cancellation,
    );

/// At 2x/3x, preserve the current response while warming the adjacent range.
/// After handoff, recycle consumed pages and refill free network slots even
/// while earlier ranges are still being consumed. Two responses and the same
/// bounded byte budget; unqualified sources keep their continuous reader.
class DiscSpeedReader {
  DiscSpeedReader(
    DiscStreamOpen open,
    this.openPart, {
    required this.partBytes,
    this.onDiagnostic,
    void Function()? onResume,
  }) : assert(
         partBytes >= DiscRangeCache.blockBytes &&
             partBytes % DiscRangeCache.blockBytes == 0,
       ) {
    _single = DiscStreamReader(
      (path, start, cancel) async {
        final source = await open(path, start, cancel);
        final expected = _continuation;
        if (expected != null && !expected.matches(source.identity)) {
          source.close(false);
          throw const DiscIdentityFailure();
        }
        return source;
      },
      onResume: onResume,
      metrics: metrics,
    );
  }
  final DiscPartOpen openPart;
  final int partBytes;
  final void Function(String)? onDiagnostic;
  late final DiscStreamReader _single;
  final metrics = DiscReadMetrics();
  Future<void> _tail = Future.value();
  final _parts = <_Part>[];
  DiscStreamIdentity? _continuation;
  String? _path;
  int? _next, _singleEnd;
  double _speed = 1;
  bool _closed = false, _disabled = false, _reportedUnqualified = false;
  bool _retiring = false;
  int _allocated = 0;
  int _spaceWaiters = 0, _spaceWaitMicros = 0;
  Stopwatch? _frontWait;
  Completer<void> _space = Completer<void>();
  Object? _failure;
  int _partOpens = 0, _partReads = 0, peakResponses = 0, peakPartBytes = 0;
  int _singleBytes = 0, _singleMicros = 0;
  int _trialBytes = 0, _trialMicros = 0, _busy = 0, _busySince = 0;
  final _clock = Stopwatch()..start();
  bool _reviewed = false;

  int get openedResponses => _single.openedResponses + _partOpens;
  int get reusedBlocks => _single.reusedBlocks + _partReads;
  int get activeResponses =>
      (_single.hasOpenSource ? 1 : 0) + _parts.where((p) => p.active).length;
  int get retainedBytes => _allocated;
  bool get hasParts => _parts.isNotEmpty || _singleEnd != null;

  Future<void> retire() async {
    await _tail;
    await _retireParts();
    await _single.retire();
    _path = null;
    _next = null;
    _continuation = null;
  }

  // Request length and storage budget serve different purposes. A slow 32 MiB
  // response can pin the next playback bytes while the fast lane fills all
  // available storage with later ranges. Keep the existing two-lane byte
  // budget, but schedule smaller, page-aligned pieces (4/8 MiB in production).
  int get rangeBytes =>
      (partBytes ~/ (4 * DiscRangeCache.blockBytes) * DiscRangeCache.blockBytes)
          .clamp(DiscRangeCache.blockBytes, 2 * DiscRangeCache.blockBytes);

  int get contiguousReadyBytes {
    if (_singleEnd != null) {
      return 0; // Continuous-to-ranged handoff is pending.
    }
    var ready = 0;
    for (final part in _parts) {
      ready += part.received - part.consumed;
      if (part.received < part.end - part.start) break;
    }
    return ready;
  }

  int get outOfOrderReadyBytes =>
      _parts.fold<int>(0, (sum, part) => sum + part.received - part.consumed) -
      contiguousReadyBytes;

  String get deliveryHealth =>
      '分段请求=${rangeBytes ~/ 1048576} MiB；'
      '连续已收=${(contiguousReadyBytes / 1048576).toStringAsFixed(2)} MiB；'
      '后段已收=${(outOfOrderReadyBytes / 1048576).toStringAsFixed(2)} MiB；'
      '本次等前段=${_frontWait?.elapsedMilliseconds ?? 0} ms；'
      '满页等待者=$_spaceWaiters；满页等待累计=${(_spaceWaitMicros / 1000000).toStringAsFixed(2)} 秒；'
      '单路比较样本=${(_singleBytes / 1048576).toStringAsFixed(2)} MiB/${_singleMicros ~/ 1000} ms；'
      '流水比较样本=${(_trialBytes / 1048576).toStringAsFixed(2)} MiB；已核对收益=$_reviewed';
  String get mode => _disabled
      ? '单路（预读已退回）'
      : _parts.isNotEmpty
      ? '流水双路'
      : '连续单路';

  void setSpeed(double speed) {
    if (!speed.isFinite || speed <= 0) return;
    _speed = speed;
    _pumpParts();
  }

  void _wakeSpace() {
    _space.complete();
    _space = Completer<void>();
  }

  Future<Uint8List> _page(_Part part, int length) async {
    while (true) {
      part.cancellation.check();
      if (_closed) throw const AppFailure('原盘读取已取消');
      // A later range must not occupy the page needed to finish an earlier
      // active range. Otherwise a full forward buffer can deadlock delivery.
      final reserved =
          _parts
              .takeWhile((p) => p != part)
              .where(
                (p) =>
                    p.active &&
                    p._pages.isEmpty &&
                    p.received < p.end - p.start,
              )
              .length *
          DiscRangeCache.blockBytes;
      if (_allocated + length + reserved <= 2 * partBytes) {
        _allocated += length;
        _samplePeak();
        return Uint8List(length);
      }
      final wait = Stopwatch()..start();
      _spaceWaiters++;
      try {
        await _space.future;
      } finally {
        _spaceWaiters--;
        _spaceWaitMicros += wait.elapsedMicroseconds;
      }
    }
  }

  void _pumpParts() {
    if (_closed ||
        _retiring ||
        _disabled ||
        _speed < 2 ||
        _singleEnd != null ||
        _parts.isEmpty ||
        _parts.any((p) => p.error != null)) {
      return;
    }
    // Network completion, rather than consumption of a whole range, frees a
    // lane. Only open work for which at least one page can be retained.
    while (activeResponses < 2 &&
        _parts.last.end < _continuation!.total &&
        _allocated + (activeResponses + 1) * DiscRangeCache.blockBytes <=
            2 * partBytes) {
      _startPart(_parts.last.end);
    }
  }

  Future<DiscRangeBlock> read(
    String path,
    int start,
    int length,
    DiscReadCancellation cancellation, {
    DiscReadProgress? onProgress,
    Uint8List? destination,
  }) {
    final result = _tail.then(
      (_) => _read(path, start, length, cancellation, onProgress, destination),
    );
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _samplePeak() {
    if (activeResponses > peakResponses) peakResponses = activeResponses;
    if (retainedBytes > peakPartBytes) peakPartBytes = retainedBytes;
    assert(activeResponses <= 2);
    assert(retainedBytes <= 2 * partBytes);
  }

  void _networkBegin() {
    if (_busy++ == 0) _busySince = _clock.elapsedMicroseconds;
  }

  void _networkEnd() {
    if (--_busy == 0) _trialMicros += _clock.elapsedMicroseconds - _busySince;
  }

  void _disable(String reason) {
    if (_disabled) return;
    _disabled = true;
    onDiagnostic?.call('倍速预读退回单路：$reason；已读数据继续使用，本次播放不反复尝试');
  }

  void _reviewGain() {
    // Compare actual active read time, excluding time sitting on a full cache.
    // Review once, after four bounded parts; never confuse the two queued cache
    // jobs with two network connections.
    if (_reviewed ||
        _trialBytes < 4 * partBytes ||
        _singleBytes < 8 * 1024 * 1024 ||
        _singleMicros < 250000) {
      return;
    }
    _reviewed = true;
    final micros =
        _trialMicros +
        (_busy == 0 ? 0 : _clock.elapsedMicroseconds - _busySince);
    if (micros > 0) {
      onDiagnostic?.call(
        '倍速读取核对：单路有效读取=${(_singleBytes / _singleMicros * 1000000 / 1048576).toStringAsFixed(2)} MiB/s；'
        '流水有效读取=${(_trialBytes / micros * 1000000 / 1048576).toStringAsFixed(2)} MiB/s；'
        '含响应头等待，不含缓存满等待；非线路测速',
      );
    }
    if (micros > 0 &&
        _trialBytes / micros < _singleBytes / _singleMicros * 1.1) {
      _disable('读取吞吐未达到单路的 1.1 倍');
    }
  }

  void _startPart(int start) {
    if (_closed) return;
    final identity = _continuation!;
    if (start >= identity.total) return;
    final end = (start + rangeBytes).clamp(start, identity.total);
    final part = _Part(this, _path!, start, end, identity);
    _parts.add(part);
    _samplePeak();
    part.begin();
  }

  Future<void> _retireParts() async {
    _retiring = true;
    final parts = _parts.toList();
    for (final part in parts) {
      part.cancel();
    }
    await Future.wait(parts.map((p) => p.done));
    for (final part in parts) {
      part.releasePages();
    }
    _parts.clear();
    _singleEnd = null;
    _retiring = false;
  }

  Future<DiscRangeBlock> _read(
    String path,
    int start,
    int length,
    DiscReadCancellation cancellation,
    DiscReadProgress? onProgress,
    Uint8List? destination,
  ) async {
    cancellation.check();
    if (_closed) throw const AppFailure('原盘读取已取消');
    if (_failure != null) throw _failure!;
    try {
      final sequential = path == _path && start == _next;
      if (!sequential) {
        await _retireParts();
        // Retire even when normal's next position differs, before any new part.
        await _single.retire();
        _continuation = null;
      }
      _path = path;
      if (sequential && _parts.isEmpty && _speed >= 2 && !_disabled) {
        final identity = _single.identity;
        if (identity != null && start + rangeBytes < identity.total) {
          _continuation = identity;
          _singleEnd = start + rangeBytes;
          _startPart(_singleEnd!);
          onDiagnostic?.call(
            '倍速流水预读启动：最多 2 路；每段 ${rangeBytes ~/ 1048576} MiB；'
            '分段内存预算=${2 * partBytes ~/ 1048576} MiB；前段优先交付；文件身份已校验；STRM 入口不重访',
          );
        } else if (identity == null && !_reportedUnqualified) {
          _reportedUnqualified = true;
          onDiagnostic?.call('倍速保持连续单路：未取得同一目标的强文件标记，不尝试拼接多路数据');
        }
      }
      // A failed optional warm-up must not destroy a still-valid continuous
      // response. Changed identity is always terminal, even during warm-up.
      for (final part in _parts) {
        if (part.error is DiscIdentityFailure) throw part.error!;
      }
      if (_singleEnd != null && _parts.firstOrNull?.error != null) {
        _disable('相邻范围读取失败，沿用当前有效连续响应');
        await _retireParts();
        _continuation = null;
      }
      if (_singleEnd == null) {
        for (final part in _parts) {
          if (part.error != null) throw part.error!;
        }
      }
      cancellation.check();
      if (_closed) throw const AppFailure('原盘读取已取消');
      DiscRangeBlock block;
      if (_singleEnd == null && _parts.isEmpty ||
          _singleEnd != null && start < _singleEnd!) {
        final watch = Stopwatch()..start();
        block = await _single.read(
          path,
          start,
          length,
          cancellation,
          onProgress: onProgress,
          destination: destination,
        );
        if (_parts.isEmpty) {
          _singleBytes += block.bytes.length;
          _singleMicros += watch.elapsedMicroseconds;
        }
        _samplePeak();
      } else {
        if (_singleEnd != null) {
          await _single.retire();
          _singleEnd = null;
        }
        // Remove a consumed part only after its socket has finished closing.
        while (_parts.isNotEmpty && start >= _parts.first.end) {
          await _parts.first.done;
          if (_parts.first.error != null) throw _parts.first.error!;
          _parts.first.releasePages();
          _parts.removeAt(0);
        }
        _reviewGain();
        if (_parts.isEmpty) {
          block = await _single.read(
            path,
            start,
            length,
            cancellation,
            onProgress: onProgress,
            destination: destination,
          );
          _samplePeak();
        } else {
          _pumpParts();
          final current = _parts.first;
          cancellation.abort = () {
            for (final part in _parts) {
              part.cancel();
            }
          };
          _frontWait = Stopwatch()..start();
          try {
            block = await current.read(
              start,
              length,
              cancellation,
              onProgress,
              destination,
            );
          } finally {
            _frontWait = null;
          }
          _partReads++;
          _pumpParts();
        }
      }
      cancellation.check();
      if (_closed) throw const AppFailure('原盘读取已取消');
      _next = start + block.bytes.length;
      return block;
    } catch (error) {
      var failure = error;
      if (error is _InterruptedPart &&
          !_closed &&
          !cancellation.cancelled &&
          _single.resumedResponses == 0) {
        // Share the existing one-recovery budget with the continuous reader.
        // A validated prefix may already have been delivered. Retire both
        // responses, then refill this block from the same identity-checked
        // target. The cache retains its longest prefix and consumers keep their
        // requested offsets, so this replay does not duplicate output bytes.
        _single.resumedResponses++;
        _disable('相邻响应正文中断，关闭旧连接后核对文件身份并恢复当前块一次');
        try {
          await _retireParts();
          await _single.retire();
          cancellation.check();
          if (_closed) throw const AppFailure('原盘读取已取消');
          final block = await _single.read(
            path,
            start,
            length,
            cancellation,
            onProgress: onProgress,
            destination: destination,
          );
          cancellation.check();
          if (_closed) throw const AppFailure('原盘读取已取消');
          _next = start + block.bytes.length;
          _samplePeak();
          return block;
        } catch (nextError) {
          failure = nextError;
        }
      }
      _next = null;
      if (!cancellation.cancelled && !_closed) _failure = failure;
      await _retireParts();
      await _single.retire();
      throw failure;
    } finally {
      cancellation.abort = null;
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final part in _parts) {
      part.cancel();
    }
    await _single.close();
    await _tail;
    await _retireParts();
  }
}

class _Part {
  _Part(this.owner, this.path, this.start, this.end, this.identity);
  final DiscSpeedReader owner;
  final String path;
  final int start, end;
  final DiscStreamIdentity identity;
  final _pages = <int, Uint8List>{};
  final cancellation = DiscReadCancellation();
  final _done = Completer<void>();
  Completer<void> _changed = Completer<void>();
  DiscStreamSource? _source;
  StreamIterator<List<int>>? _iterator;
  int received = 0, consumed = 0;
  bool active = false;
  Object? error;
  Future<void> get done => _done.future;
  void _pulse() {
    _changed.complete();
    _changed = Completer<void>();
  }

  void begin() {
    unawaited(_fill());
  }

  void cancel() {
    cancellation.cancel();
    _source?.close(false);
    _pulse();
    owner._wakeSpace();
  }

  void releasePages({int? before}) {
    for (final entry in _pages.entries.toList()) {
      if (before != null && entry.key + entry.value.length > before) continue;
      owner._allocated -= entry.value.length;
      _pages.remove(entry.key);
    }
    owner._wakeSpace();
  }

  Future<void> _fill() async {
    active = true;
    owner._samplePeak();
    try {
      late final DiscStreamSource source;
      owner._networkBegin();
      try {
        source = await owner.metrics.opening(
          () => owner.openPart(path, start, end - 1, identity, cancellation),
        );
      } finally {
        owner._networkEnd();
      }
      _source = source;
      owner._partOpens++;
      cancellation.check();
      if (source.start != start || !identity.matches(source.identity)) {
        throw const DiscIdentityFailure();
      }
      final iterator = _iterator = StreamIterator(source.bytes);
      cancellation.abort = () {
        source.close(false);
        _pulse();
      };
      while (true) {
        cancellation.check();
        owner._networkBegin();
        bool more;
        try {
          more = await owner.metrics.next(iterator);
        } finally {
          owner._networkEnd();
        }
        cancellation.check();
        if (!more) break;
        final chunk = iterator.current;
        if (received + chunk.length > end - start) {
          throw const DiscIdentityFailure();
        }
        owner._trialBytes += chunk.length;
        var at = 0;
        while (at < chunk.length) {
          cancellation.check();
          final pageAt =
              received ~/ DiscRangeCache.blockBytes * DiscRangeCache.blockBytes;
          final page = _pages[pageAt] ??= await owner._page(
            this,
            (end - start - pageAt).clamp(0, DiscRangeCache.blockBytes),
          );
          final count = (chunk.length - at).clamp(
            0,
            page.length - (received - pageAt),
          );
          final copyWatch = Stopwatch()..start();
          page.setRange(
            received - pageAt,
            received - pageAt + count,
            chunk,
            at,
          );
          owner.metrics.copyMicroseconds += copyWatch.elapsedMicroseconds;
          received += count;
          at += count;
          _pulse();
        }
      }
      if (received != end - start) throw const _InterruptedPart();
      source.close(true);
    } catch (e) {
      error =
          _source != null &&
              (e is SocketException ||
                  e is TimeoutException ||
                  e is HttpException &&
                      e.message.toLowerCase().contains('connection closed'))
          ? const _InterruptedPart()
          : e;
      _source?.close(false);
      if (!cancellation.cancelled) {
        // Status/identity details are logged by the transport; do not log URLs.
        owner.onDiagnostic?.call('相邻预读未完成；保留读取错误，不重访 STRM 入口');
      }
    } finally {
      cancellation.abort = null;
      await _iterator?.cancel();
      active = false;
      _done.complete();
      _pulse();
      owner._wakeSpace();
      owner._pumpParts();
    }
  }

  Future<DiscRangeBlock> read(
    int offset,
    int length,
    DiscReadCancellation cancel,
    DiscReadProgress? onProgress,
    Uint8List? destination,
  ) async {
    final count = (end - offset).clamp(0, length);
    if (offset < start || count != (identity.total - offset).clamp(0, length)) {
      throw const DiscIdentityFailure();
    }
    if (destination != null && destination.length < count) {
      throw const AppFailure('原盘读取目标缓冲不足');
    }
    final data = destination == null
        ? Uint8List(count)
        : Uint8List.sublistView(destination, 0, count);
    var written = 0, published = 0;
    while (written < count) {
      cancel.check();
      cancellation.check();
      if (error != null) throw error!;
      final ready = (received - (offset - start)).clamp(written, count);
      if (ready > written) {
        final copyWatch = Stopwatch()..start();
        while (written < ready) {
          final relative = offset - start + written;
          final pageAt =
              relative ~/ DiscRangeCache.blockBytes * DiscRangeCache.blockBytes;
          final page = _pages[pageAt];
          if (page == null) throw const DiscIdentityFailure();
          final n = (ready - written).clamp(
            0,
            page.length - (relative - pageAt),
          );
          data.setRange(written, written + n, page, relative - pageAt);
          written += n;
        }
        owner.metrics.copyMicroseconds += copyWatch.elapsedMicroseconds;
        consumed = offset - start + written;
        releasePages(before: consumed);
        if (onProgress != null &&
            written < count &&
            written - published >= 256 * 1024) {
          published = written;
          onProgress(
            DiscRangeBlock(
              offset,
              identity.total,
              Uint8List.sublistView(data, 0, written),
            ),
          );
        }
      }
      if (written < count) await _changed.future;
    }
    return DiscRangeBlock(offset, identity.total, data);
  }
}

class _InterruptedPart extends AppFailure {
  const _InterruptedPart() : super('原盘相邻范围响应正文中断或提前结束');
}
