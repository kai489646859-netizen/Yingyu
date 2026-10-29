import 'dart:convert';
import 'package:flutter/services.dart';

/// Exact numeric row from our optional codec hint; arbitrary native text stays out.
String? codecWorkloadMessage(String prefix, String text) {
  if (prefix != 'ffmpeg/video' || text.length > 180) return null;
  final line = text.trim();
  if (line.contains('\n') || line.contains('\r')) return null;
  final match = RegExp(
    r'^(?:(?:hevc|h264|mpeg2|mpeg4|vp8|vp9|av1)_mediacodec: )?'
    r'Yingyu codec workload request=(\d{1,4}\.\d{3}) '
    r'result=(unavailable|call-complete)$',
  ).firstMatch(line);
  if (match == null) return null;
  final rate = double.tryParse(match[1]!);
  if (rate == null || rate <= 0 || rate > 1000) return null;
  return '硬解处理速率请求=${rate.toStringAsFixed(3)} fps；'
      '接口调用=${match[2] == 'call-complete' ? '完成' : '不支持或失败，沿用原播放'}；'
      '非实际吞吐保证';
}

/// Only fixed labels and bounded numbers leave this read-only probe.
Future<String?> readRenderMetrics({
  required Future<String> Function(String) read,
  required bool Function() active,
  Future<dynamic> Function()? readDisplay,
}) async {
  final fields = <String>[];
  for (final key in const [
    'container-fps',
    'display-fps',
    'estimated-display-fps',
  ]) {
    if (!active()) return null;
    String? result;
    try {
      final raw = await read(key).timeout(const Duration(milliseconds: 180));
      final value = raw.length <= 32 ? double.tryParse(raw) : null;
      if (value != null && value.isFinite && value > 0 && value <= 1000) {
        result = value.toStringAsFixed(3);
      }
    } catch (_) {
      // Unsupported optional diagnostics never alter playback.
    }
    fields.add('$key=${result ?? '未提供'}');
  }
  if (!active()) return null;
  try {
    final raw = await read(
      'vo-passes',
    ).timeout(const Duration(milliseconds: 180));
    if (!active()) return null;
    if (raw.length > 65536) throw const FormatException();
    // The pinned MPV exposes this as one node map. It does not implement a
    // key action for vo-passes/fresh, even though the map contains that array.
    final node = jsonDecode(raw);
    final value = node is Map ? node['fresh'] : null;
    if (value is! List || value.isEmpty || value.length > 32) {
      throw const FormatException();
    }
    var fused = false;
    var timed = true;
    double total = 0;
    for (final pass in value) {
      if (pass is! Map) throw const FormatException();
      final last = pass['last'];
      final count = pass['count'];
      if (last is num &&
          last.isFinite &&
          last >= 0 &&
          last <= 10000000000 &&
          count is num &&
          count.isFinite &&
          count > 0 &&
          count <= 1024) {
        total += last.toDouble();
      } else {
        timed = false;
      }
      fused |= pass['desc'] == 'output to screen (Yingyu fused gain)';
    }
    fields.add('输出合并=${fused ? 'yes' : 'no'}');
    fields.add('渲染阶段数=${value.length}');
    fields.add(
      timed
          ? '末次GPU阶段合计=${(total / 1000000).toStringAsFixed(3)} ms'
          : 'GPU阶段计时=未提供',
    );
  } catch (_) {
    fields.add('GPU阶段计时=未提供');
  }
  if (!active()) return null;
  try {
    final rates =
        await (readDisplay ??
                () => const MethodChannel(
                  'yingyu/device',
                ).invokeMethod('displayRates'))()
            .timeout(const Duration(milliseconds: 180));
    if (!active()) return null;
    if (rates is Map) {
      for (final entry in const {
        'appHz': 'Android应用刷新率',
        'modeHz': '物理显示模式',
        'maximumHz': '同分辨率可用最高刷新率',
      }.entries) {
        final value = rates[entry.key];
        fields.add(
          '${entry.value}=${value is num && value.isFinite && value > 0 && value <= 1000 ? '${value.toStringAsFixed(3)} Hz' : '未提供'}',
        );
      }
    } else {
      fields.add('Android刷新率=未提供');
    }
  } catch (_) {
    fields.add('Android刷新率=未提供');
  }
  return active() ? fields.join('；') : null;
}
