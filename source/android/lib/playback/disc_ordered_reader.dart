import 'dart:async';
import 'dart:collection';
import 'dart:io' show FileSystemException;
import 'dart:typed_data';
import '../core/models.dart';
import 'disc_cache.dart';
import 'disc_stream.dart';
import 'disc_speed_reader.dart';
import 'disc_forward_spool.dart';

/// A bounded producer independent of native block requests. Continuous input
/// is retained until a qualified speed/starvation hint can safely use two lanes.
/// Request cancellation retires the producer before reuse.
class DiscOrderedReader {
  DiscOrderedReader(
    DiscStreamOpen open, {
    required this.maxBytes,
    void Function()? onResume,
    DiscPartOpen? openPart,
    void Function(String)? onDiagnostic,
  }) : _onDiagnostic = onDiagnostic,
       assert(maxBytes >= chunkBytes && maxBytes % chunkBytes == 0),
       _parallel =
           openPart != null && maxBytes >= 3 * DiscRangeCache.blockBytes,
       _reader = DiscSpeedReader(
         open,
         openPart ?? ((_, _, _, _, _) => throw const DiscIdentityFailure()),
         partBytes:
             (maxBytes ~/
                     (6 * DiscRangeCache.blockBytes) *
                     DiscRangeCache.blockBytes)
                 .clamp(DiscRangeCache.blockBytes, 8 * 1024 * 1024),
         onResume: onResume,
         onDiagnostic: onDiagnostic,
       );

  static const chunkBytes = 64 * 1024;
  static const _openingSampleBytes = 1024 * 1024;
  static const _largeDiscBytes = 32 * 1024 * 1024 * 1024;
  final int maxBytes;
  final DiscSpeedReader _reader;
  final bool _parallel;
  final void Function(String)? _onDiagnostic;
  final _clock = Stopwatch()..start();
  double _speed = 1;
  bool _starved = false, _openingDemand = false;
  Timer? _largeRecoveryTimer;
  String? _spoolDirectory;
  int _forwardBytes = 0;
  bool _spoolUnavailable = false;
  bool get _recoveringNormalSpeed =>
      _speed == 1 && _session?.recovering == true;
  bool get _accelerating =>
      _speed >= 2 || (_speed > 1 && _starved) || _recoveringNormalSpeed;
  int get _queueLimit =>
      maxBytes -
      (_parallel && (_accelerating || _reader.hasParts)
          ? 2 * _reader.partBytes
          : 0);
  void setSpeed(double speed) {
    if (_speed != speed) cancelLargeRecovery();
    _speed = speed;
    _updateDemand();
  }

  void setBuffering(bool value, {bool recoverLargeInput = false}) {
    if (!value || !recoverLargeInput) {
      _largeRecoveryTimer?.cancel();
    } else if (!_starved && _parallel && _speed == 1) {
      final session = _session;
      if (session != null &&
          session.supplyEligible &&
          !session.recovering &&
          (session.total ?? 0) >= _largeDiscBytes) {
        _largeRecoveryTimer?.cancel();
        _largeRecoveryTimer = Timer(const Duration(seconds: 3), () {
          if (_closed ||
              !_starved ||
              _speed != 1 ||
              _session != session ||
              session.cancelled ||
              session.retained >= 1024 * 1024) {
            return;
          }
          session.recovering = true;
          _updateDemand();
        });
      }
    }
    _starved = value;
    _updateDemand();
  }

  void cancelLargeRecovery() {
    _largeRecoveryTimer?.cancel();
    if (_session case final session?) {
      session.recovering = false;
    }
    _updateDemand();
  }

  void configureForwardSpool(String? directory, int bytes) {
    _spoolDirectory = directory;
    _forwardBytes = bytes ~/ chunkBytes * chunkBytes;
    _session?.pulse();
  }

  void setOpeningDemand(bool value) {
    _openingDemand = value;
    _updateDemand();
  }

  void _spoolFailed() {
    if (_spoolUnavailable) return;
    _spoolUnavailable = true;
    _onDiagnostic?.call('原盘临时磁盘缓存不可用，继续原生直读');
  }

  // Brief ordinary-speed starvation keeps the continuous response. Only
  // sustained starvation on large native disc inputs can try an adjacent range.
  void _updateDemand() {
    _reader.setSpeed(
      _parallel &&
              (_session?.supplyEligible == true ||
                  _openingDemand && _recoveringNormalSpeed) &&
              _accelerating
          ? (_speed >= 2 ? _speed : 2)
          : 1,
      recovery: _recoveringNormalSpeed,
      opening: _openingDemand,
    );
    _session?.trimSpares();
    _session?.pulse();
  }

  bool _canRecoverOpening(_OrderedSession session) =>
      _openingDemand &&
      _parallel &&
      _speed == 1 &&
      !session.recovering &&
      (session.total ?? 0) >= _largeDiscBytes &&
      session.consumed - session.start >= _openingSampleBytes;

  _OrderedSession? _session;
  Future<void> _tail = Future.value();
  bool _closed = false;
  int reusedBlocks = 0, peakBytes = 0;
  int fullWaitMicroseconds = 0;
  Object? _failure;
  DiscReadMetrics get metrics => _reader.metrics;
  int get openedResponses => _reader.openedResponses;
  int get activeResponses => _reader.activeResponses;
  int get peakResponses => _reader.peakResponses;
  int get retainedBytes =>
      (_session?.storageBytes ?? 0) + _reader.retainedBytes;
  String get mode => '${_reader.mode}（有序小块）';
  String get deliveryHealth =>
      '顺序队列=${(retainedBytes / 1048576).toStringAsFixed(2)} MiB；'
      '原盘磁盘前向缓存=${((_session?.diskUnread ?? 0) / 1048576).toStringAsFixed(2)} MiB；'
      '待交付数据=${((_session?.retained ?? 0) / 1048576).toStringAsFixed(2)} MiB；'
      '复用空闲内存=${((_session?.spares.length ?? 0) * chunkBytes / 1048576).toStringAsFixed(2)} MiB；'
      '顺序队列上限=${maxBytes ~/ 1048576} MiB；交付小块=64 KiB；'
      '满队列等待累计=${(fullWaitMicroseconds / 1000000).toStringAsFixed(2)} 秒；${_reader.deliveryHealth}';

  Future<DiscRangeBlock> read(
    String path,
    int start,
    int length,
    DiscReadCancellation cancellation, {
    DiscReadProgress? onProgress,
    bool availableOnly = false,
  }) {
    final result = _tail.then((_) async {
      try {
        return await _read(
          path,
          start,
          length,
          cancellation,
          onProgress,
          availableOnly,
        );
      } on _DiscSpoolFailure {
        _spoolFailed();
        final current = _session;
        current?.cancel();
        if (current != null) await current.release();
        _session = null;
        cancellation.check();
        return _read(
          path,
          start,
          length,
          cancellation,
          onProgress,
          availableOnly,
        );
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<DiscRangeBlock> _read(
    String path,
    int start,
    int length,
    DiscReadCancellation cancellation,
    DiscReadProgress? progress,
    bool availableOnly,
  ) async {
    cancellation.check();
    if (_closed) throw const AppFailure('原盘读取已取消');
    if (_failure != null) throw _failure!;
    if (start < 0 || start % chunkBytes != 0 || length <= 0) {
      throw const AppFailure('原盘顺序读取范围无效');
    }
    var session = _session;
    if (session == null ||
        session.cancelled ||
        session.path != path ||
        start < session.consumed ||
        (start != session.consumed && start > session.published)) {
      session?.cancel();
      if (session != null) await session.release();
      await _reader.retire();
      cancellation.check();
      if (_closed) throw const AppFailure('原盘读取已取消');
      session = _OrderedSession(this, path, start);
      _session = session;
      _updateDemand();
      session.done = session.produce();
    } else {
      reusedBlocks++;
    }
    final current = session;
    cancellation.abort = current.cancel;
    current.demand = start + length;
    current.pulse();
    Uint8List? output;
    var limit = length;
    var written = 0, announced = 0;
    int? openingWaitStart;
    try {
      while (written < limit) {
        cancellation.check();
        if (_closed || current.cancelled) {
          throw const AppFailure('原盘读取已取消');
        }
        final total = current.total;
        if (total != null && start + written == total) break;
        final block = current.ready.isEmpty ? null : current.ready.first;
        if (block == null) {
          if (current.error != null) throw current.error!;
          final spool = current.spool;
          final diskStart = current.diskStart;
          final at = start + written;
          if (spool != null && diskStart != null && at < current.published) {
            if (at < diskStart) throw const _DiscSpoolFailure();
            if (output == null) {
              if (availableOnly) {
                limit = (current.published - start).clamp(1, length);
              }
              output = Uint8List(limit);
            }
            final count = (current.published - at).clamp(0, limit - written);
            try {
              await spool.readInto(at, output, written, count);
            } on FileSystemException {
              throw const _DiscSpoolFailure();
            }
            cancellation.check();
            if (_closed || current.cancelled) {
              throw const AppFailure('原盘读取已取消');
            }
            written += count;
            current.consumed = start + written;
            current.pulse();
            continue;
          }
          if (availableOnly && written > 0) break;
          if (_canRecoverOpening(current)) {
            openingWaitStart ??= _clock.elapsedMicroseconds;
          }
          await current.changed.future;
          continue;
        }
        if (openingWaitStart case final began?) {
          openingWaitStart = null;
          if (_canRecoverOpening(current)) {
            current.openingWaitMicros += _clock.elapsedMicroseconds - began;
            if (current.openingWaitMicros >= 1500000) {
              current.recovering = true;
              _onDiagnostic?.call('原盘开播读取等待累计达到 1.5 秒，尝试提前预热相邻范围');
              _updateDemand();
            }
          }
        }
        if (block.start + block.bytes.length <= start + written) {
          current.take();
          continue;
        }
        final at = start + written - block.start;
        if (at < 0 || at >= block.bytes.length) {
          throw const AppFailure('原盘顺序队列字节范围不连续');
        }
        // Allocate only the prefix we will return. Repeated 64 KiB early
        // deliveries must not allocate/retain a full 1 MiB request each time.
        if (output == null) {
          if (availableOnly) {
            limit = (current.published - start).clamp(1, length);
          }
          output = Uint8List(limit);
        }
        final count = (block.bytes.length - at).clamp(0, limit - written);
        final watch = Stopwatch()..start();
        output.setRange(written, written + count, block.bytes, at);
        metrics.copyMicroseconds += watch.elapsedMicroseconds;
        written += count;
        current.consumed = start + written;
        if (!current.supplyEligible &&
            current.consumed - current.start >= 8 * 1024 * 1024) {
          // Preserve enough real single-response reads for the gain comparison.
          current.supplyEligible = true;
          _updateDemand();
        }
        if (at + count == block.bytes.length) current.take();
        // Do not read an entire distant file after a metadata-sized demand.
        if (!current.prefetch &&
            current.consumed - current.start >= 1024 * 1024) {
          current.prefetch = true;
          _updateDemand();
          current.pulse();
        }
        if (progress != null &&
            written < limit &&
            written - announced >= chunkBytes) {
          announced = written;
          progress(
            DiscRangeBlock(
              start,
              block.total,
              Uint8List.sublistView(output, 0, written),
            ),
          );
        }
      }
      cancellation.check();
      return DiscRangeBlock(
        start,
        current.total!,
        Uint8List.sublistView(output ?? Uint8List(0), 0, written),
      );
    } finally {
      cancellation.abort = null;
    }
  }

  Future<void> close() async {
    _closed = true;
    _largeRecoveryTimer?.cancel();
    final current = _session;
    current?.cancel();
    if (current != null) await current.release();
    await _reader.close();
  }
}

class _OrderedSession {
  _OrderedSession(this.owner, this.path, this.start)
    : consumed = start,
      published = start,
      demand = start;
  final DiscOrderedReader owner;
  final String path;
  final int start;
  final cancellation = DiscReadCancellation();
  final ready = Queue<DiscRangeBlock>();
  final spares = <Uint8List>[];
  Completer<void> changed = Completer<void>();
  Future<void> done = Future.value();
  int consumed, published, demand, retained = 0;
  int openingWaitMicros = 0;
  int? total;
  int get storageBytes =>
      retained + spares.length * DiscOrderedReader.chunkBytes;
  bool prefetch = false, supplyEligible = false, recovering = false;
  Object? error;
  DiscForwardSpool? spool;
  int? diskStart;
  int get diskUnread {
    final start = diskStart;
    if (start == null) return 0;
    return (published - (consumed > start ? consumed : start)).clamp(
      0,
      spool!.size,
    );
  }

  bool get cancelled => cancellation.cancelled;

  void pulse() {
    changed.complete();
    changed = Completer<void>();
  }

  void cancel() {
    cancellation.cancel();
    ready.clear();
    spares.clear();
    retained = 0;
    pulse();
  }

  Future<void> release() async {
    await done;
    await spool?.close();
  }

  int get _forwardLimit {
    if (owner._spoolUnavailable ||
        owner._spoolDirectory == null ||
        owner._forwardBytes <= owner._queueLimit ||
        !prefetch) {
      return owner._queueLimit;
    }
    final size = spool?.size;
    return size != null && size < owner._forwardBytes
        ? size
        : owner._forwardBytes;
  }

  bool get _full {
    final limit = _forwardLimit;
    final buffered = diskUnread == 0 ? retained : published - consumed;
    return buffered + DiscOrderedReader.chunkBytes > limit;
  }

  bool get _needsSpool =>
      spool == null &&
      _forwardLimit > owner._queueLimit &&
      retained + DiscOrderedReader.chunkBytes > owner._queueLimit;

  Future<void> _openSpool() async {
    try {
      spool = await DiscForwardSpool.open(
        owner._spoolDirectory!,
        published,
        _forwardLimit,
      );
    } on FileSystemException {
      owner._spoolFailed();
    }
  }

  void take() {
    final block = ready.removeFirst();
    retained -= block.bytes.length;
    if (block.bytes.length == DiscOrderedReader.chunkBytes) {
      spares.add(block.bytes);
    }
    trimSpares();
    pulse();
  }

  void trimSpares() {
    final count =
        ((owner._queueLimit - retained) ~/ DiscOrderedReader.chunkBytes).clamp(
          0,
          spares.length,
        );
    if (count < spares.length) spares.removeRange(count, spares.length);
  }

  Future<void> produce() async {
    try {
      while (!cancelled && (total == null || published < total!)) {
        if (_needsSpool) await _openSpool();
        while (!cancelled && (_full || (!prefetch && published >= demand))) {
          final full = _full;
          final watch = Stopwatch()..start();
          await changed.future;
          if (full) owner.fullWaitMicroseconds += watch.elapsedMicroseconds;
          if (_needsSpool) await _openSpool();
        }
        cancellation.check();
        final block = await owner._reader.read(
          path,
          published,
          DiscOrderedReader.chunkBytes,
          cancellation,
          destination: spares.isEmpty
              ? Uint8List(DiscOrderedReader.chunkBytes)
              : spares.removeLast(),
        );
        cancellation.check();
        if (block.start != published ||
            block.bytes.isEmpty ||
            (total != null && block.total != total)) {
          throw const DiscIdentityFailure();
        }
        total = block.total;
        final target = spool;
        if (target == null ||
            diskUnread == 0 &&
                retained + block.bytes.length <= owner._queueLimit) {
          diskStart = null;
          ready.add(block);
          retained += block.bytes.length;
          if (retained > owner.peakBytes) owner.peakBytes = retained;
        } else {
          final firstOffset = diskUnread == 0 ? published : diskStart;
          try {
            await target.append(published, block.bytes);
          } on FileSystemException {
            throw const _DiscSpoolFailure();
          }
          cancellation.check();
          diskStart = firstOffset;
          if (block.bytes.length == DiscOrderedReader.chunkBytes) {
            spares.add(block.bytes);
            trimSpares();
          }
        }
        published += block.bytes.length;
        pulse();
      }
    } catch (e) {
      if (!cancelled && !owner._closed) {
        error = e;
        if (e is! _DiscSpoolFailure) owner._failure = e;
      }
    } finally {
      pulse();
    }
  }
}

class _DiscSpoolFailure implements Exception {
  const _DiscSpoolFailure();
}
