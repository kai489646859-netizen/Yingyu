import 'package:flutter/services.dart';
import 'log.dart';
import 'native_crash.dart';
import 'anr_trace.dart';

Future<void> recordPreviousExit(DiagnosticLog log) async {
  if (!log.enabled) return;
  try {
    final value = await const MethodChannel(
      'yingyu/device',
    ).invokeMapMethod<String, dynamic>('previousExit');
    if (value == null || value['supported'] != true) {
      log.add(LogArea.app, '系统未提供历史进程退出原因（需要 Android 11 或以上）');
      return;
    }
    if (value['timestamp'] is! int) {
      log.add(LogArea.app, '系统没有可用的历史进程退出记录');
      return;
    }
    final reason = switch (value['reason']) {
      1 => '应用自行退出',
      2 => '系统信号终止',
      3 => '系统内存不足',
      4 => 'Java 未处理异常',
      5 => '原生代码崩溃',
      6 => '应用无响应',
      10 => '用户或系统请求停止',
      11 => '用户停止',
      _ => '其他系统原因',
    };
    log.add(
      LogArea.app,
      '上次进程退出：${DateTime.fromMillisecondsSinceEpoch(value['timestamp'] as int).toIso8601String()}；原因=$reason；原因码=${value['reason']}；状态=${value['status']}；系统最后采样内存=${value['pssKb']} KB（非退出瞬间）',
    );
  } catch (_) {
    log.add(LogArea.app, '系统进程退出原因读取失败', level: LogLevel.warning);
  } finally {
    await Future.wait([recordNativeCrash(log), recordAnrTrace(log)]);
  }
}
