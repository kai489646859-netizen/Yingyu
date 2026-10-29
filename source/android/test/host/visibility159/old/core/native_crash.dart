import 'dart:async';
import 'package:flutter/services.dart';
import 'log.dart';
import 'historical_diagnostic.dart';

// Temporary CRASH094 diagnostic. Raw system traces never cross this channel.
Future<void> recordNativeCrash(DiagnosticLog log) async {
  if (!log.enabled) return;
  const prefix = '[CRASH094] 原生崩溃堆栈';
  try {
    final report = await const MethodChannel('yingyu/device')
        .invokeMapMethod<String, dynamic>('nativeCrashTrace')
        .timeout(const Duration(seconds: 4));
    final status = report?['status'];
    final stamp = report?['timestamp'];
    final time = stamp is int && stamp > 0 && stamp < 4102444800000
        ? DateTime.fromMillisecondsSinceEpoch(stamp).toIso8601String()
        : '未提供';
    if (status != 'available') {
      final message = switch (status) {
        'none' => '系统没有保留映屿原生崩溃记录',
        'unsupported' => '直接读取堆栈需要 Android 12 或以上',
        'unavailable' => '系统堆栈不可用，可能已被覆盖',
        'too_large' => '系统记录超过诊断读取上限',
        'expired' => '后台诊断达到读取时间上限',
        'wrong_process' => '系统堆栈与映屿进程不匹配，已忽略',
        'reading' => '后台诊断仍在读取，不重复启动',
        _ => '系统记录无法安全解析',
      };
      log.add(LogArea.app, '$prefix：$message；历史记录时间=$time');
      return;
    }
    final marker = historicalReportMarker('CRASH', report!);
    if (historicalReportExists(log, marker)) return;
    final rawSignal = report['signal'];
    final signal = rawSignal is int && rawSignal > 0 && rawSignal <= 127
        ? '$rawSignal'
        : '未提供';
    final arch = switch (report['arch']) {
      'arm' => 'arm',
      'arm64' => 'arm64',
      'x86' => 'x86',
      'x86_64' => 'x86_64',
      _ => 'unknown',
    };
    final kind = switch (report['abortKind']) {
      'assertion' => '断言终止',
      'double_free' => '重复释放',
      'allocator' => '内存分配器检查',
      'fd_sanitizer' => '文件句柄检查',
      'fortify' => '边界检查',
      'jni' => 'JNI 检查',
      'allocation_failure' => '内存申请失败',
      'cpp_terminate' => 'C++ 终止',
      _ => '其他或未提供',
    };
    final frames = report['frames'];
    log.add(
      LogArea.app,
      '$prefix：时间=$time；信号=$signal；ABI=$arch；类别=$kind；'
      '帧截断=${report['framesTruncated'] == true}；线程截断=${report['threadsTruncated'] == true}；本次启动补录，补录时间不等于发生时间',
    );
    if (frames is! List) return;
    for (final frame in frames.take(64)) {
      if (frame is! Map) continue;
      final index = frame['index'], pc = frame['pc'];
      if (index is! int ||
          index < 0 ||
          index >= 64 ||
          pc is! String ||
          !RegExp(r'^[0-9a-f]{1,16}$').hasMatch(pc)) {
        continue;
      }
      final name = frame['library'], id = frame['buildId'];
      final library =
          name is String &&
              RegExp(
                r'^lib[A-Za-z0-9_.+-]{1,90}\.so(?:\.[0-9]+)*$',
              ).hasMatch(name)
          ? name
          : 'unknown';
      final build = id is String && RegExp(r'^[0-9a-f]{16,128}$').hasMatch(id)
          ? [
              for (var at = 0; at < id.length; at += 8)
                id.substring(at, (at + 8).clamp(0, id.length)),
            ].join('.')
          : '未提供';
      log.add(
        LogArea.app,
        '[CRASH094] 原生崩溃帧 #${index.toString().padLeft(2, '0')}：'
        '库=$library；相对PC=0x$pc；BuildID=$build',
      );
    }
    log.add(LogArea.app, marker);
  } on TimeoutException {
    log.add(LogArea.app, '$prefix：等待后台诊断超时，应用继续运行');
  } catch (_) {
    log.add(LogArea.app, '$prefix：诊断读取不可用，应用继续运行');
  }
}
