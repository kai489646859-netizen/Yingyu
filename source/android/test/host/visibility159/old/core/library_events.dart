import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'emby.dart';
import 'log.dart';
import 'models.dart';

class LibraryEventChannel {
  LibraryEventChannel(this.messages, this.send, this.close);
  final Stream<dynamic> messages;
  final void Function(String) send;
  final Future<void> Function() close;
}

Uri libraryEventUri(Session account) => account.base.replace(
  scheme: account.base.scheme == 'https' ? 'wss' : 'ws',
  path: '${account.base.path}websocket',
  queryParameters: {'api_key': account.token, 'deviceId': account.deviceId},
);

/// One authenticated upgrade, without redirects or additional API probes.
/// Explicit handshake prevents a reverse proxy redirect forwarding credentials.
Future<LibraryEventChannel> connectLibraryEvents(Session account) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  Future<LibraryEventChannel> connect() async {
    final target = libraryEventUri(account);
    final request = await client.getUrl(
      target.replace(scheme: target.scheme == 'wss' ? 'https' : 'http'),
    );
    request.followRedirects = false;
    final random = Random.secure();
    final nonce = base64Encode(List.generate(16, (_) => random.nextInt(256)));
    request.headers
      ..set('Connection', 'Upgrade')
      ..set('Upgrade', 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Key', nonce);
    final response = await request.close();
    final accept = base64Encode(
      sha1
          .convert(utf8.encode('${nonce}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
          .bytes,
    );
    if (response.statusCode != 101 ||
        response.headers.value('Upgrade')?.toLowerCase() != 'websocket' ||
        !(response.headers
                .value('Connection')
                ?.toLowerCase()
                .split(',')
                .any((v) => v.trim() == 'upgrade') ??
            false) ||
        response.headers.value('Sec-WebSocket-Accept') != accept) {
      throw const AppFailure('服务器资源变更通知暂不可用');
    }
    final socket = WebSocket.fromUpgradedSocket(
      await response.detachSocket(),
      serverSide: false,
      compression: CompressionOptions.compressionOff,
    )..pingInterval = const Duration(seconds: 60);
    return LibraryEventChannel(socket, socket.add, () async {
      await socket.close();
    });
  }

  try {
    return await connect().timeout(const Duration(seconds: 8));
  } finally {
    client.close(force: true);
  }
}

/// Notifications only: no per-event HTTP fetch, polling, or remote commands.
/// Missing events while disconnected are handled by the normal manual refresh.
class LibraryEvents {
  LibraryEvents(
    this.api, {
    required this.onChanges,
    Future<LibraryEventChannel> Function(Session)? connect,
    this.coalesce = const Duration(milliseconds: 500),
    this.retryBase = const Duration(seconds: 30),
  }) : account = api.session!,
       connect = connect ?? connectLibraryEvents;
  final EmbyClient api;
  final Session account;
  final Future<LibraryEventChannel> Function(Session) connect;
  final Future<void> Function(Set<String> removed, Set<String> added) onChanges;
  final Duration coalesce, retryBase;
  LibraryEventChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry, _batch;
  Future<void> _writes = Future.value();
  DateTime? _retryAt, _connectedAt;
  bool _active = false, _disposed = false, _connecting = false;
  int _generation = 0, _failures = 0;
  final _removed = <String>{}, _added = <String>{};
  bool get current => !_disposed && identical(account, api.session);
  bool get connected => current && _active && _channel != null;
  bool _valid(int generation) =>
      current && _active && generation == _generation;
  void setActive(bool value) {
    if (_disposed || value == _active) return;
    _active = value;
    if (value) {
      _schedule();
    } else {
      _generation++;
      _retry?.cancel();
      _batch?.cancel();
      _flush();
      _disconnect();
    }
  }

  void _schedule() {
    if (!current || !_active || _connecting || _channel != null) return;
    final wait = _retryAt?.difference(DateTime.now()) ?? Duration.zero;
    if (wait > Duration.zero) {
      _retry?.cancel();
      _retry = Timer(wait, _open);
    } else {
      unawaited(_open());
    }
  }

  Future<void> _open() async {
    if (!current || !_active || _connecting || _channel != null) return;
    _connecting = true;
    final generation = _generation;
    try {
      final channel = await connect(account);
      if (!_valid(generation)) {
        unawaited(channel.close());
        return;
      }
      _channel = channel;
      _connectedAt = DateTime.now();
      _subscription = channel.messages.listen(
        (value) {
          if (_valid(generation)) _message(value);
        },
        onError: (Object _) {
          if (_valid(generation)) _lost();
        },
        onDone: () {
          if (_valid(generation)) _lost();
        },
        cancelOnError: true,
      );
      api.log?.add(LogArea.app, '资源变更通知已连接');
    } catch (_) {
      if (_valid(generation)) _lost();
    } finally {
      _connecting = false;
      if (current && _active && _channel == null) _schedule();
    }
  }

  void _disconnect() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    final previous = _channel;
    _channel = null;
    if (previous != null) unawaited(previous.close().catchError((Object _) {}));
  }

  void _lost() {
    _generation++;
    _disconnect();
    if (_connectedAt != null &&
        DateTime.now().difference(_connectedAt!) > const Duration(minutes: 2)) {
      _failures = 0;
    }
    _connectedAt = null;
    _failures = (_failures + 1).clamp(1, 5);
    final delay = Duration(
      milliseconds: min(
        retryBase.inMilliseconds * (1 << (_failures - 1)),
        300000,
      ),
    );
    _retryAt = DateTime.now().add(delay);
    api.log?.add(
      LogArea.app,
      '资源变更通知中断，${delay.inSeconds} 秒后重连；未追加媒体查询',
      level: LogLevel.warning,
    );
    _schedule();
  }

  void _message(dynamic raw) {
    if (raw is! String || raw.length > 1024 * 1024) return;
    try {
      final event = jsonDecode(raw);
      if (event is! Map) return;
      if (event['MessageType'] == 'ForceKeepAlive') {
        _channel?.send('{"MessageType":"KeepAlive"}');
        return;
      }
      if (event['MessageType'] != 'LibraryChanged') return;
      final data = event['Data'];
      if (data is! Map) return;
      Set<String> ids(String name) {
        final values = data[name] ?? const [];
        if (values is! List ||
            values.length > 10000 ||
            values.any(
              (id) =>
                  id is! String ||
                  id.isEmpty ||
                  id.length > 128 ||
                  id.contains(RegExp(r'[\x00-\x20]')),
            )) {
          throw const FormatException('Invalid library change');
        }
        return values.cast<String>().toSet();
      }

      final removed = ids('ItemsRemoved'), added = ids('ItemsAdded');
      // Preserve arrival order across messages; a removal wins within one batch.
      _removed.removeAll(added);
      _added.addAll(added);
      _added.removeAll(removed);
      _removed.addAll(removed);
      _batch ??= Timer(coalesce, _flush);
    } catch (_) {
      api.log?.add(LogArea.app, '资源变更通知格式无效，已保留缓存', level: LogLevel.warning);
    }
  }

  void _flush() {
    _batch?.cancel();
    _batch = null;
    if (_removed.isEmpty && _added.isEmpty) return;
    final removed = Set<String>.of(_removed), added = Set<String>.of(_added);
    _removed.clear();
    _added.clear();
    _writes = _writes.then((_) async {
      if (!current) return;
      try {
        await onChanges(removed, added);
        api.log?.add(
          LogArea.app,
          '资源通知本机处理：删除=${removed.length}；新增标记=${added.length}；媒体查询=0',
        );
      } catch (_) {
        api.log?.add(LogArea.app, '资源通知本机保存失败，请刷新重试', level: LogLevel.warning);
      }
    });
  }

  Future<void> get settled => _writes;
  void dispose() {
    if (_disposed) return;
    setActive(false);
    _disposed = true;
  }
}
