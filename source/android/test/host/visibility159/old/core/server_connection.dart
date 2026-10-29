import 'package:flutter/foundation.dart';

enum ServerStatus { unknown, connected, disconnected, unavailable, denied }

/// Only authenticated Emby API outcomes update this state, never poster or
/// external media failures. Older concurrent results cannot replace newer ones.
class ServerConnection extends ChangeNotifier {
  ServerStatus status = ServerStatus.unknown;
  String? detail;
  int? latencyMs;
  DateTime? checkedAt;
  int recovery = 0, _sequence = 0, _latest = 0;
  int begin() => ++_sequence;
  bool get hasProblem =>
      status != ServerStatus.unknown && status != ServerStatus.connected;
  String get label => switch (status) {
    ServerStatus.unknown => '尚未测试连接',
    ServerStatus.connected => 'Emby 服务器已连接',
    ServerStatus.disconnected => 'Emby 服务器连接已断开',
    ServerStatus.unavailable => 'Emby 服务器暂时不可用',
    ServerStatus.denied => 'Emby 服务器认证或访问失败',
  };

  void finish(int ticket, ServerStatus next, {String? reason, int? elapsedMs}) {
    if (ticket < _latest) return;
    _latest = ticket;
    final recovered = hasProblem && next == ServerStatus.connected;
    final changed = status != next || detail != reason;
    status = next;
    detail = reason;
    latencyMs = elapsedMs;
    checkedAt = DateTime.now();
    if (recovered) recovery++;
    if (changed || recovered) notifyListeners();
  }

  void reset() {
    _latest = ++_sequence;
    status = ServerStatus.unknown;
    detail = null;
    latencyMs = null;
    checkedAt = null;
    recovery = 0;
    notifyListeners();
  }
}
