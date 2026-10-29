/// Whitelisted numeric diagnostics. CPU API durations are not hardware latency
/// or atomic A/V samples. Native records may span pause/rate/seek boundaries.
String? pipelineStageMessage(String prefix, String text) {
  if (text.length > 320) return null;
  final copied = RegExp(
    r'^Yingyu copy143 queue samples=([0-6])$',
  ).firstMatch(text.trim());
  if (prefix == 'vd' && copied != null) {
    if (copied[1] == '0') return '本次保留原解码通路；直接硬件帧、杜比或显式队列策略不强制改写';
    return '复制或软件输出工作队列=${copied[1]} 帧；按实际 CPU 画面与内存预算调整，不代表实际呈现帧率';
  }
  final queue = RegExp(
    r'^Yingyu copy142 queue samples=(0|1|6)$',
  ).firstMatch(text.trim());
  if (prefix == 'vd' && queue != null) {
    if (queue[1] == '0') return '本次视频未启用普通 SDR 复制输出工作队列，保留原解码通路';
    return '普通 SDR 复制输出工作队列=${queue[1]} 帧；只扩大已复制的 P010 画面队列，不代表实际呈现帧率';
  }
  final match = RegExp(
    r'^(?:(?:hevc|h264|mpeg2|mpeg4|vp8|vp9|av1)_mediacodec: )?'
    r'Yingyu stage136 name=(input_wait|output_wait|copy_api|copy_drop|upload_api|swap_api|fence_api) '
    r'window_us=(\d{1,18}) calls=(\d{1,18}) ok=(\d{1,18}) '
    r'total_us=(\d{1,18}) max_us=(\d{1,18}) serial=(\d{1,10})$',
  ).firstMatch(text.trim());
  if (match == null) return null;
  final name = match[1]!;
  final codec = const {
    'input_wait',
    'output_wait',
    'copy_api',
    'copy_drop',
  }.contains(name);
  if (codec
      ? !const {'ffmpeg/video', 'vd'}.contains(prefix)
      : !const {
          'vo/gpu/opengl',
          'vo/gpu',
          'vo/gpu-next/opengl',
        }.contains(prefix)) {
    return null;
  }
  final values = [for (var i = 2; i <= 7; i++) int.tryParse(match[i]!)];
  if (values.any((v) => v == null)) return null;
  final window = values[0]!;
  final calls = values[1]!;
  final ok = values[2]!;
  final total = values[3]!;
  final maximum = values[4]!;
  if (window < 2000000 ||
      calls <= 0 ||
      ok > calls ||
      maximum > total ||
      total > window ||
      values[5]! > 4294967295) {
    return null;
  }
  final note = name == 'copy_drop' ? '；calls为复制前过时输出释放次数，不能作为流畅度结论' : '';
  return '原生阶段统计 name=$name window_us=$window calls=$calls ok=$ok '
      'total_us=$total max_us=$maximum serial=${values[5]}；'
      'CPU接口计时，非解码/GPU执行延迟；跨操作窗口需分开核对$note';
}
