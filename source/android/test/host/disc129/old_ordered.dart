import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_stream.dart';
import 'package:yingyu/playback/disc_speed_reader.dart';

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
  }) : assert(maxBytes >= chunkBytes && maxBytes % chunkBytes == 0),
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
  final int maxBytes;
  final DiscSpeedReader _reader;
  final bool _parallel;
  double _speed = 1;
  bool _starved = false;
  int get _queueLimit =>
      maxBytes -
      (_parallel && (_speed >= 2 || _starved || _reader.hasParts)
          ? 2 * _reader.partBytes
          : 0);
  void setSpeed(double speed) {
    _speed = speed;
    _updateDemand();
  }

  void setBuffering(bool value) {
    _starved = value;
    _updateDemand();
  }

  void _updateDemand() {
    _reader.setSpeed(
      _parallel &&
              _session != null &&
              _session!.supplyEligible &&
              (_speed >= 2 || _starved)
          ? (_speed >= 2 ? _speed : 2)
          : 1,
    );
    _session?.trimSpares();
    _session?.pulse();
  }

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
    final result = _tail.then(
      (_) =>
          _read(path, start, length, cancellation, onProgress, availableOnly),
    );
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
      if (session != null) await session.done;
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
          if (availableOnly && written > 0) break;
          await current.changed.future;
          continue;
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
    final current = _session;
    current?.cancel();
    if (current != null) await current.done;
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
  int? total;
  int get storageBytes =>
      retained + spares.length * DiscOrderedReader.chunkBytes;
  bool prefetch = false, supplyEligible = false;
  Object? error;
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
        while (!cancelled &&
            (retained + DiscOrderedReader.chunkBytes > owner._queueLimit ||
                (!prefetch && published >= demand))) {
          final full =
              retained + DiscOrderedReader.chunkBytes > owner._queueLimit;
          final watch = Stopwatch()..start();
          await changed.future;
          if (full) owner.fullWaitMicroseconds += watch.elapsedMicroseconds;
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
        ready.add(block);
        published += block.bytes.length;
        retained += block.bytes.length;
        if (retained > owner.peakBytes) owner.peakBytes = retained;
        pulse();
      }
    } catch (e) {
      if (!cancelled && !owner._closed) {
        error = e;
        owner._failure = e;
      }
    } finally {
      pulse();
    }
  }
}
