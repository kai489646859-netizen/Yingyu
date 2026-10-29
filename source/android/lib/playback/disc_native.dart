import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:media_kit/ffi/ffi.dart';
import '../core/models.dart';
import 'disc_cache.dart';

/// Async native IO messages go to the media isolate, never the UI isolate.
/// Request IDs, not raw native destination pointers, survive cancellation.
class DiscNativeApi {
  DiscNativeApi({String? libraryPath})
    : library = DynamicLibrary.open(libraryPath ?? 'libyingyu_disc.so');
  final DynamicLibrary library;
  late final register = library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('yd_register');
  late final open = library
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int64, Pointer<Void>, Int32),
        int Function(Pointer<Utf8>, int, Pointer<Void>, int)
      >('yd_open');
  late final select = library
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Utf8>)
      >('yd_select');
  late final reply = library
      .lookupFunction<
        Void Function(Int64, Int32, Int64, Pointer<Uint8>, Int32),
        void Function(int, int, int, Pointer<Uint8>, int)
      >('yd_reply');
  late final selectIndex = library
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('yd_select_index');
  late final close = library
      .lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('yd_close');
  late final stat = library
      .lookupFunction<
        Int64 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('yd_stat');

  void cancel(String id) {
    final text = id.toNativeUtf8();
    try {
      close(text);
    } finally {
      calloc.free(text);
    }
  }
}

class DiscNativeSession {
  DiscNativeSession(this.id, this.input, {String? libraryPath})
    : api = DiscNativeApi(libraryPath: libraryPath),
      _name = id.toNativeUtf8();
  final String id;
  final Future<DiscRangeBlock?> Function(
    int,
    String,
    int,
    int,
    DiscReadCancellation,
  )
  input;
  final _pending = <int, DiscReadCancellation>{};
  final DiscNativeApi api;
  final Pointer<Utf8> _name;
  ReceivePort? _events;
  Completer<String>? _opening;
  Completer<String>? _indexing;
  bool _closed = false;
  int _copyUs = 0;

  String get health {
    if (_closed) return '原生读取已退出';
    int value(int key) => api.stat(_name, key);
    return '原生直读=${(value(0) / 1048576).toStringAsFixed(2)} MiB；'
        '原生请求=${value(1)}；原生输入等待=${value(2) ~/ 1000} ms；'
        '原生读回调=${value(3) ~/ 1000} ms（包含输入等待，不可相加）；'
        '原生页命中=${value(4)}；桥接复制=${_copyUs ~/ 1000} ms；'
        '本机 HTTP 转发=0；Java 媒体数组=0；';
  }

  Future<Object?> invoke(String method, Map<String, Object?> args) async {
    if (method == 'close') {
      close();
      return null;
    }
    if (_closed) throw const AppFailure('播放已退出');
    switch (method) {
      case 'open':
        if (_opening != null) throw const AppFailure('原盘已打开');
        final opening = _opening = Completer<String>();
        unawaited(opening.future.catchError((Object _) => ''));
        _events = ReceivePort()
          ..listen((dynamic event) {
            if (_closed || event is! List || event.isEmpty) return;
            if (event[0] == -1) {
              final indexing = _indexing;
              if (indexing != null && !indexing.isCompleted) {
                indexing.complete(event[1] == 0 ? event[2] as String : '[]');
              }
            } else if (event[0] == 0) {
              if (opening.isCompleted) return;
              if (event[1] == 0) {
                opening.complete(event[2] as String);
              } else {
                opening.completeError(
                  AppFailure(
                    event[1] == -2
                        ? '原盘含 AACS 或 BD+ 加密，当前无法读取'
                        : '原盘目录或播放列表读取失败，请查看网络读取日志',
                  ),
                );
              }
            } else if (event[1] == 0) {
              _pending[event[0]]?.cancel();
            } else {
              unawaited(_read(event));
            }
          });
        final result = api.open(
          _name,
          _events!.sendPort.nativePort,
          NativeApi.postCObject.cast(),
          args['iso'] == true ? 1 : 0,
        );
        if (result < 0) throw const AppFailure('原生原盘读取未能启动');
        return opening.future;
      case 'select':
        final clips = (args['clips'] as List)
            .cast<String>()
            .join(',')
            .toNativeUtf8();
        try {
          if (api.select(_name, clips) < 0) throw const AppFailure('原盘片段选择失败');
        } finally {
          calloc.free(clips);
        }
        return null;
      case 'selectIndex':
        if (_indexing != null) return _indexing!.future;
        final indexing = _indexing = Completer<String>();
        unawaited(indexing.future.catchError((Object _) => '[]'));
        try {
          if (api.selectIndex(_name, args['playlist'] as int) < 0) {
            indexing.complete('[]');
          }
        } catch (_) {
          indexing.complete('[]');
        }
        return indexing.future;
      default:
        throw const AppFailure('原生原盘控制操作无效');
    }
  }

  Future<void> _read(List event) async {
    final request = event[0] as int;
    final token = DiscReadCancellation();
    _pending[request] = token;
    var status = -1, total = -1;
    Uint8List? bytes;
    try {
      final block = await input(
        event[1] as int,
        event[2] as String,
        event[3] as int,
        event[4] as int,
        token,
      );
      if (block != null) {
        status = 0;
        total = block.total;
        bytes = block.bytes;
      }
    } catch (_) {
      // Transport owns the sanitized error. No exception text/URL crosses FFI.
    }
    _pending.remove(request);
    if (_closed) return;
    final watch = Stopwatch()..start();
    final pointer = bytes == null || bytes.isEmpty
        ? nullptr
        : malloc<Uint8>(bytes.length);
    try {
      if (bytes != null && bytes.isNotEmpty) {
        pointer.asTypedList(bytes.length).setAll(0, bytes);
      }
      api.reply(request, status, total, pointer, bytes?.length ?? 0);
    } finally {
      if (pointer != nullptr) malloc.free(pointer);
      _copyUs += watch.elapsedMicroseconds;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final token in _pending.values) {
      token.cancel();
    }
    _pending.clear();
    api.close(_name); // wakes C++ readers without waiting for network or MPV
    _events?.close();
    if (_opening case final opening? when !opening.isCompleted) {
      opening.completeError(const AppFailure('播放已退出'));
    }
    if (_indexing case final indexing? when !indexing.isCompleted) {
      indexing.completeError(const AppFailure('播放已退出'));
    }
    calloc.free(_name);
  }
}
