/// Process CPU is summed across threads. Heaps exclude GPU/codec buffers and
/// are not total process PSS. Battery temperature is not CPU temperature.
class ResourceObservation {
  double? _cpu, _elapsed;
  String describe(Map<Object?, Object?> values) {
    double? number(String key) {
      final v = values[key];
      return v is num && v.isFinite && v >= 0 && v < 1e16 ? v.toDouble() : null;
    }

    final cpu = number('cpuMs'), elapsed = number('elapsedMs');
    final beforeCpu = _cpu, beforeElapsed = _elapsed;
    String usage = '未提供';
    if (cpu != null &&
        elapsed != null &&
        beforeCpu != null &&
        beforeElapsed != null &&
        cpu >= beforeCpu &&
        elapsed > beforeElapsed) {
      usage =
          '${((cpu - beforeCpu) / (elapsed - beforeElapsed) * 100).toStringAsFixed(1)}%（单核100%，所有线程合计）';
    }
    _cpu = cpu;
    _elapsed = elapsed;
    return '进程CPU区间=$usage；${[
      for (final key in const ['javaHeapBytes', 'nativeHeapBytes', 'batteryPercent', 'batteryTempC', 'plugged', 'powerSave', 'thermal']) '$key=${number(key) ?? "未提供"}',
    ].join('；')}；堆内存不含GPU/解码器且非PSS；电池温度非CPU温度；电量变化不等于本软件耗电';
  }

  void reset() {
    _cpu = null;
    _elapsed = null;
  }
}
