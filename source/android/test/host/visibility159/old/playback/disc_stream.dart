import 'dart:async';
import 'dart:io' show HttpException, SocketException;
import 'dart:typed_data';
import '../core/models.dart';
import 'disc_cache.dart';

/// One HTTP response, requested from [start] to EOF. Pulling its iterator only
/// when the bounded block cache asks for data provides socket backpressure.
class DiscStreamSource {
  DiscStreamSource({
    required this.start,
    required this.total,
    required this.bytes,
    required this.close,
    this.canResume = false,
    this.validator,
    this.identity,
  });
  final int start, total;
  final Stream<List<int>> bytes;
  final void Function(bool fullyRead) close;
  final bool canResume;
  final String? validator;
  // Present only for an exact target with a strong ETag. Never logged.
  final DiscStreamIdentity? identity;
}

class DiscStreamIdentity {
  const DiscStreamIdentity(this.address, this.tag, this.total);
  final String address, tag;
  final int total;

  bool matches(DiscStreamIdentity? other) =>
      other != null &&
      address == other.address &&
      tag == other.tag &&
      total == other.total;
}

class DiscIdentityFailure extends AppFailure {
  const DiscIdentityFailure() : super('原盘预读的文件身份或范围发生变化，已停止读取');
}

typedef DiscStreamOpen =
    Future<DiscStreamSource> Function(
      String path,
      int start,
      DiscReadCancellation cancellation,
    );

/// Observations at the HTTP-stream consumer, not a physical line-speed test.
/// Waiting sums can overlap across two responses. Copy time is synchronous
/// work only; the receive window includes application scheduling/backpressure.
class DiscReadMetrics {
  final _clock = Stopwatch()..start();
  final _opening = <Stopwatch>{}, _waiting = <Stopwatch>{};
  int receivedBytes = 0, openMicroseconds = 0, bodyMicroseconds = 0;
  int copyMicroseconds = 0;
  int _windowAt = 0, _windowBytes = 0, _windowDuration = 0, _windowReceived = 0;

  Future<T> opening<T>(Future<T> Function() action) async {
    final watch = Stopwatch()..start();
    _opening.add(watch);
    try {
      return await action();
    } finally {
      openMicroseconds += watch.elapsedMicroseconds;
      _opening.remove(watch);
    }
  }

  Future<bool> next(StreamIterator<List<int>> iterator) async {
    final watch = Stopwatch()..start();
    _waiting.add(watch);
    try {
      final more = await iterator.moveNext().timeout(
        const Duration(seconds: 30),
      );
      if (more) receivedBytes += iterator.current.length;
      return more;
    } finally {
      bodyMicroseconds += watch.elapsedMicroseconds;
      _waiting.remove(watch);
    }
  }

  String get health {
    final now = _clock.elapsedMicroseconds;
    if (now - _windowAt >= 3000000) {
      _windowDuration = now - _windowAt;
      _windowReceived = receivedBytes - _windowBytes;
      _windowAt = now;
      _windowBytes = receivedBytes;
    }
    final open =
        openMicroseconds +
        _opening.fold<int>(0, (n, watch) => n + watch.elapsedMicroseconds);
    final body =
        bodyMicroseconds +
        _waiting.fold<int>(0, (n, watch) => n + watch.elapsedMicroseconds);
    return '读取器正文已收=${(receivedBytes / 1048576).toStringAsFixed(2)} MiB；'
        '接收观察窗口=${(_windowDuration / 1000000).toStringAsFixed(2)} 秒；'
        '窗口收到=${(_windowReceived / 1048576).toStringAsFixed(2)} MiB；'
        '响应建立累计=${open ~/ 1000} ms；正文等待累计=${body ~/ 1000} ms；'
        '读取复制累计=${copyMicroseconds ~/ 1000} ms（等待可重叠，非线路测速）';
  }
}

class DiscStreamReader {
  DiscStreamReader(this.open, {this.onResume, DiscReadMetrics? metrics})
    : metrics = metrics ?? DiscReadMetrics();
  final DiscStreamOpen open;
  final void Function()? onResume;
  final DiscReadMetrics metrics;
  Future<void> _tail = Future.value();
  DiscStreamSource? _source;
  StreamIterator<List<int>>? _iterator;
  List<int> _remaining = const [];
  int _remainingAt = 0, _position = 0;
  String? _path;
  bool _closed = false;
  Object? _failure;
  int openedResponses = 0, reusedBlocks = 0;
  int resumedResponses = 0;
  bool get hasOpenSource => _source != null;
  DiscStreamIdentity? get identity => _source?.identity;

  /// The caller serializes this with read. Finish retirement before opening a
  /// replacement, so a handoff/seek can never temporarily add a third socket.
  Future<void> retire() async {
    await _tail;
    await _release();
  }

  Future<void> _resumeBody(
    Object error,
    DiscStreamSource previous,
    DiscReadCancellation cancellation,
  ) async {
    final transient =
        error is SocketException ||
        error is TimeoutException ||
        error is _TruncatedBody ||
        error is HttpException &&
            error.message.toLowerCase().contains('connection closed');
    if (!transient ||
        !previous.canResume ||
        resumedResponses >= 1 ||
        cancellation.cancelled ||
        _closed) {
      throw error;
    }
    final position = _position;
    await _release();
    cancellation.check();
    if (_closed) throw const AppFailure('原盘读取已取消');
    resumedResponses++;
    onResume?.call();
    // The production opener reuses only an already resolved external URL.
    // This never overlaps the old response and never revisits a STRM entry.
    final next = await metrics.opening(
      () => open(_path!, position, cancellation),
    );
    if (_closed || cancellation.cancelled) {
      next.close(false);
      throw const AppFailure('原盘读取已取消');
    }
    if (next.start != position ||
        next.total != previous.total ||
        previous.validator != null && next.validator != previous.validator) {
      next.close(false);
      throw const AppFailure('原盘续读内容与原文件不一致，已停止播放');
    }
    _source = next;
    _iterator = StreamIterator(next.bytes);
    openedResponses++;
    cancellation.abort = () => unawaited(_release());
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

  Future<void> _release({bool fullyRead = false}) async {
    final source = _source, iterator = _iterator;
    _source = null;
    _iterator = null;
    _remaining = const [];
    _remainingAt = 0;
    source?.close(fullyRead);
    await iterator?.cancel();
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
      if (_source == null || _path != path || _position != start) {
        await _release();
        cancellation.check();
        if (_closed) throw const AppFailure('原盘读取已取消');
        final source = await metrics.opening(
          () => open(path, start, cancellation),
        );
        if (_closed || cancellation.cancelled) {
          source.close(false);
          throw const AppFailure('原盘读取已取消');
        }
        _source = source;
        _iterator = StreamIterator(source.bytes);
        _path = path;
        _position = start;
        openedResponses++;
      } else {
        reusedBlocks++;
      }
      final source = _source!;
      if (source.start > start || source.total <= start) {
        throw const AppFailure('原盘连续响应范围无效');
      }
      final count = (source.total - start).clamp(0, length);
      if (destination != null && destination.length < count) {
        throw const AppFailure('原盘读取目标缓冲不足');
      }
      final result = destination == null
          ? Uint8List(count)
          : Uint8List.sublistView(destination, 0, count);
      var written = 0, published = 0;
      cancellation.abort = () {
        unawaited(_release());
      };
      while (written < result.length) {
        cancellation.check();
        if (_closed) throw const AppFailure('原盘读取已取消');
        if (_remainingAt == _remaining.length) {
          final iterator = _iterator;
          try {
            if (iterator == null || !await metrics.next(iterator)) {
              throw const _TruncatedBody();
            }
          } catch (error) {
            await _resumeBody(error, source, cancellation);
            continue;
          }
          cancellation.check();
          _remaining = iterator.current;
          _remainingAt = 0;
          if (_remaining.isEmpty) continue;
        }
        final count = (_remaining.length - _remainingAt).clamp(
          0,
          result.length - written,
        );
        final copyWatch = Stopwatch()..start();
        result.setRange(written, written + count, _remaining, _remainingAt);
        metrics.copyMicroseconds += copyWatch.elapsedMicroseconds;
        _remainingAt += count;
        written += count;
        _position += count;
        if (onProgress != null &&
            written < result.length &&
            written - published >= 256 * 1024) {
          published = written;
          onProgress(
            DiscRangeBlock(
              start,
              source.total,
              Uint8List.sublistView(result, 0, written),
            ),
          );
        }
      }
      cancellation.check();
      if (_position == source.total) {
        if (_remainingAt != _remaining.length) {
          throw const AppFailure('原盘连续响应超出声明的文件长度');
        }
        await _release(fullyRead: true);
      }
      return DiscRangeBlock(start, source.total, result);
    } catch (error) {
      // No retry storm: a real failed stream remains failed until explicit
      // playback retry. Cancelling obsolete speculation is not a media error.
      if (!cancellation.cancelled && !_closed) _failure = error;
      await _release();
      rethrow;
    } finally {
      cancellation.abort = null;
    }
  }

  Future<void> close() async {
    _closed = true;
    await _release();
  }
}

class _TruncatedBody extends AppFailure {
  const _TruncatedBody() : super('原盘连续响应提前结束');
}
