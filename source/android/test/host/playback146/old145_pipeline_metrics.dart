/// Whitelisted numeric diagnostics. CPU API durations are not hardware latency
/// or atomic A/V samples. Native records may span pause/rate/seek boundaries.
String? pipelineStageMessage(String prefix, String text) {
  if (text.length > 320) return null;
  final nonref = RegExp(
    r'^Yingyu nonref145 packets=(\d{1,18})$',
  ).firstMatch(text.trim());
  if (prefix == 'ffmpeg/video' && nonref != null) {
    final count = int.tryParse(nonref[1]!);
    if (count == null || count <= 0) return null;
    return '倍速非参考画面处理：累计跳过=$count；仅过时 HEVC 非参考画面；'
        '不是实际呈现帧率或流畅度验收';
  }
  final state = RegExp(
    r'^Yingyu queue144 samples=(\d{1,2}) frames=(\d{1,2}) '
    r'bytes=(\d{1,10}) budget=(\d{1,10}) rate_milli=(\d{1,6}) cpu=([01])$',
  ).firstMatch(text.trim());
  if (prefix == 'vd' && state != null) {
    final v = [for (var i = 1; i <= 6; i++) int.parse(state[i]!)];
    if (v[0] < 1 ||
        v[0] > 6 ||
        v[1] > 64 ||
        v[2] > 2147483647 ||
        v[3] > 160 * 1024 * 1024 ||
        v[4] > 100000) {
      return null;
    }
    return '解码队列核对：配置=${v[0]} 帧；当前排队=${v[1]} 帧；'
        '图像估计=${v[2]} 字节；预算=${v[3]} 字节；速率千分值=${v[4]}；'
        'CPU输出=${v[5]}；0速率表示尚未取得提示；非实际呈现帧率';
  }
  final body = RegExp(
    r'^Yingyu body144 window_us=(\d{1,18}) calls=(\d{1,18}) ok=(\d{1,18}) '
    r'total_us=(\d{1,18}) max_us=(\d{1,18}) bytes=(\d{1,18}) epoch=(\d{1,10})$',
  ).firstMatch(text.trim());
  if ((prefix == 'ffmpeg' || prefix.startsWith('ffmpeg/')) && body != null) {
    final v = [for (var i = 1; i <= 7; i++) int.tryParse(body[i]!)];
    if (v.any((n) => n == null)) return null;
    final n = v.cast<int>();
    if (n[0] < 2000000 ||
        n[1] <= 0 ||
        n[2] > n[1] ||
        n[4] > n[3] ||
        n[3] > n[0] ||
        n[6] > 4294967295) {
      return null;
    }
    return '媒体正文读取核对：window_us=${n[0]} calls=${n[1]} ok=${n[2]} '
        'total_us=${n[3]} max_us=${n[4]} bytes=${n[5]} epoch=${n[6]}；'
        'HTTP读取接口计时与返回字节，含等待及缓冲读取，非实测带宽；不同窗口不可混算';
  }
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
    r'Yingyu stage136 name=(input_wait|output_wait|copy_api|copy_drop|upload_api|swap_api|fence_api|get_buffer|alloc_frame|plane_copy|release_output) '
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
    'get_buffer',
    'alloc_frame',
    'plane_copy',
    'release_output',
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
