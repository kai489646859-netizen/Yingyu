import 'dart:async';
import 'package:flutter/services.dart';
import 'log.dart';
import 'historical_diagnostic.dart';

Future<void> recordAnrTrace(DiagnosticLog log) async {
  if (!log.enabled) return;
  const prefix = '[ANR095] 应用无响应堆栈';
  try {
    final report = await const MethodChannel('yingyu/device')
        .invokeMapMethod<String, dynamic>('anrTrace')
        .timeout(const Duration(seconds: 4));
    final handles = report?['currentOpenFds'];
    if (handles is int && handles >= 0 && handles < 10000000) {
      log.add(LogArea.app, '[ANR095] 当前映屿打开的句柄数量=$handles；启动诊断采样');
    }
    final stamp = report?['timestamp'];
    final time = stamp is int && stamp > 0 && stamp < 4102444800000
        ? DateTime.fromMillisecondsSinceEpoch(stamp).toIso8601String()
        : '未提供';
    if (report?['status'] != 'available') {
      final status = switch (report?['status']) {
        'none' => '系统没有保留映屿无响应记录',
        'unsupported' => '需要 Android 11 或以上',
        'unavailable' => '系统堆栈不可用，可能已被覆盖',
        'too_large' => '系统记录超过读取上限',
        'expired' => '后台读取达到时间上限',
        'wrong_process' => '记录与映屿进程不匹配，已忽略',
        'reading' => '后台正在读取，不重复启动',
        _ => '系统记录无法安全解析',
      };
      log.add(LogArea.app, '$prefix：$status；历史记录时间=$time');
      return;
    }
    final marker = historicalReportMarker('ANR', report!);
    if (historicalReportExists(log, marker)) return;
    final association = switch (report['association']) {
      'pid-match' => '进程编号已核对',
      'pid-mismatch' => '进程编号不一致，不能把堆栈归入该退出事件',
      'time-mismatch' => '堆栈晚于退出事件，不能据退出时间判断故障版本',
      _ => '系统信息不足，堆栈归属尚未确认',
    };
    log.add(
      LogArea.app,
      '$prefix（本次启动补录）：系统退出时间=$time；'
      '堆栈采样时间=${diagnosticTime(report['traceTimestamp'])}；'
      '$association；截断=${report['truncated'] == true}；保留故障证据，补录时间不等于发生时间',
      level:
          const {
            'pid-mismatch',
            'time-mismatch',
          }.contains(report['association'])
          ? LogLevel.warning
          : LogLevel.info,
    );
    final threads = report['threads'];
    if (threads is! List) return;
    var count = 0;
    for (final thread in threads.take(64)) {
      if (thread is! Map) continue;
      final id = thread['id'];
      if (id is! int || id < 0 || id > 999999999) continue;
      final role = switch (thread['role']) {
        'main' => '主线程',
        'raster' => '图形线程',
        'io' => 'IO线程',
        _ => '其他线程',
      };
      final state = switch (thread['state']) {
        'Native' => 'Native',
        'Runnable' => 'Runnable',
        'Blocked' => 'Blocked',
        'Waiting' => 'Waiting',
        'TimedWaiting' => 'TimedWaiting',
        'Suspended' => 'Suspended',
        _ => 'unknown',
      };
      log.add(LogArea.app, '[ANR095] 线程=$id；类型=$role；状态=$state');
      final owner = thread['owner'];
      if (owner is int && owner > 0 && owner <= 999999999) {
        log.add(LogArea.app, '[ANR095] 线程=$id；等待锁所属线程=$owner');
      }
      final frames = thread['frames'];
      if (frames is! List) continue;
      for (final frame in frames.take(32)) {
        if (frame is! Map || count >= 256) continue;
        if (frame['kind'] == 'java') {
          final method = frame['method'];
          if (method is String &&
              RegExp(
                r'^(?:android\.|java\.|javax\.|dalvik\.|io\.flutter\.|com\.yingyu\.|com\.alexmercerind\.)[A-Za-z0-9_.$]{1,220}$',
              ).hasMatch(method)) {
            log.add(LogArea.app, '[ANR095] 线程=$id；Java=$method');
            count++;
          }
        } else if (frame['kind'] == 'native') {
          final pc = frame['pc'], name = frame['library'];
          if (pc is! String || !RegExp(r'^[0-9a-f]{1,16}$').hasMatch(pc)) {
            continue;
          }
          final library =
              name is String &&
                  RegExp(
                    r'^lib[A-Za-z0-9_.+-]{1,90}\.so(?:\.[0-9]+)*$',
                  ).hasMatch(name)
              ? name
              : 'unknown';
          final buildId = frame['buildId'];
          final build =
              buildId is String &&
                  RegExp(r'^[0-9a-f]{16,128}$').hasMatch(buildId)
              ? [
                  for (var at = 0; at < buildId.length; at += 8)
                    buildId.substring(at, (at + 8).clamp(0, buildId.length)),
                ].join('.')
              : '未提供';
          log.add(
            LogArea.app,
            '[ANR095] 线程=$id；库=$library；相对PC=0x$pc；BuildID=$build',
          );
          count++;
        }
      }
    }
    log.add(LogArea.app, marker);
  } on TimeoutException {
    log.add(LogArea.app, '$prefix：等待后台诊断超时，应用继续运行');
  } catch (_) {
    log.add(LogArea.app, '$prefix：诊断读取不可用，应用继续运行');
  }
}
