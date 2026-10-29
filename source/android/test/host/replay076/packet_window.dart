import 'dart:async';
import 'package:yingyu/playback/packet_trace.dart';
enum LogArea { player }
enum LogLevel { warning }
class TraceLog {
  bool enabled=true;
  final rows=<String>[];
  void add(LogArea area,String row,{LogLevel? level}) { rows.add(row); }
}
class NativePlayer {
  bool disposed=false;
  final ctx=(address:1);
  String option='all=warn';
  final levels=<String>[];
  final writes=<String>[];
  int result=0;
  Completer<String>? readGate;
  Future<String> getProperty(String key) async => readGate==null ? option : await readGate!.future;
  Future<void> setProperty(String key,String value) async { option=value; writes.add(value); }
}
class PacketWindowHarness {
  PacketWindowHarness(this.native):player=(platform:native);
  final NativePlayer native;
  final ({Object platform}) player;
  bool _disposed=false;
  TraceLog? log=TraceLog();
  ({int selected})? _disc=(selected:1);
  void ordinary() { _disc=null; }
  bool get active=>_packetTrace!=null;
  Future<void> start()=>_startPacketTrace(native);
  Future<void> stop()=>_stopPacketTrace();
  Future<void> close() async { _disposed=true; await _stopPacketTrace(); }
  int _nativeLogLevel(NativePlayer native,String value) { native.levels.add(value); return native.result; }
  DiscPacketTrace? _packetTrace;
  Timer? _packetTimer;
  String? _packetPreviousLevel;
  Future<void> _packetCleanup = Future.value();

  Future<void> _startPacketTrace(NativePlayer native) async {
    await _stopPacketTrace();
    if (_disposed || log?.enabled != true || _disc?.selected == null) return;
    try {
      _packetPreviousLevel = await native
          .getProperty('options/msg-level')
          .timeout(const Duration(milliseconds: 600));
      await native
          .setProperty('msg-level', 'all=warn,demux=trace,ffmpeg/video=trace')
          .timeout(const Duration(seconds: 2));
      if (_disposed) {
        await _stopPacketTrace();
        return;
      }
      _packetTrace = DiscPacketTrace();
      // Public API terminal-default honors the prefix whitelist even with
      // terminal output disabled. Global trace would trace HTTP/auth as well.
      if (_nativeLogLevel(native, 'terminal-default') < 0) {
        throw StateError('native log request failed');
      }
      _packetTimer = Timer(
        const Duration(seconds: 45),
        () => unawaited(_stopPacketTrace()),
      );
      log?.add(
        LogArea.player,
        '原盘数值诊断开始：最长 45 秒或 20000 条事件；'
        '只保留容器/时间线 PTS、DTS 与硬解入出队数值；每类首 4 条及末 12 条',
      );
    } catch (_) {
      await _stopPacketTrace();
      log?.add(LogArea.player, '原盘数值诊断未启用，播放继续沿用原配置', level: LogLevel.warning);
    }
  }

  Future<void> _stopPacketTrace() {
    _packetTimer?.cancel();
    _packetTimer = null;
    final trace = _packetTrace;
    final previous = _packetPreviousLevel;
    _packetTrace = null;
    _packetPreviousLevel = null;
    final native = player.platform;
    if (native is NativePlayer &&
        !native.disposed &&
        native.ctx.address != 0 &&
        (trace != null || previous != null)) {
      _nativeLogLevel(native, 'warn');
      _packetCleanup = _packetCleanup.then((_) async {
        if (previous == null || native.disposed) return;
        try {
          await native
              .setProperty('msg-level', previous)
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          log?.add(
            LogArea.player,
            '原生日志等级还原未确认，客户端已恢复警告级别',
            level: LogLevel.warning,
          );
        }
      });
    }
    for (final row in trace?.finish() ?? <String>[]) {
      log?.add(LogArea.player, row);
    }
    return _packetCleanup;
  }

}
