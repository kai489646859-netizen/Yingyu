/// Whitelisted numeric diagnostics. CPU API durations are not hardware latency
/// or atomic A/V samples. Native records may span pause/rate/seek boundaries.
String? pipelineStageMessage(String prefix, String text) {
  // YY169-BEGIN
  final probe169 = _probe169StageMessage(prefix, text);
  if (probe169 != null) return probe169;
  // YY169-END
  if (text.length > 320) return null;
  final timing = RegExp(
    r'^Yingyu timing162 video=(-?\d{1,12}\.\d{6}) audio=(-?\d{1,12}\.\d{6}) '
    r'timer=(-?\d{1,12}\.\d{6}) delay=(-?\d{1,12}\.\d{6}) ao=(-?\d{1,12}\.\d{6}) '
    r'vspeed=(-?\d{1,12}\.\d{6}) aspeed=(-?\d{1,12}\.\d{6}) correction=(-?\d{1,12}\.\d{6}) '
    r'duration_ns=(-?\d{1,12}) queued=(\d{1,2}) span_us=(\d{1,9})$',
  ).firstMatch(text.trim());
  if (prefix == 'cplayer' && timing != null) {
    final values = [for (var i = 1; i <= 8; i++) double.parse(timing[i]!)];
    final duration = int.parse(timing[9]!), queued = int.parse(timing[10]!);
    final span = int.parse(timing[11]!);
    if (values.any((n) => !n.isFinite || n.abs() > 1e9) ||
        values[0] < 0 ||
        values[1] < 0 ||
        values[5] <= 1 ||
        values[5] > 3 ||
        values[6] <= 0 ||
        values[6] > 16 ||
        duration < 0 ||
        duration > 10000000000 ||
        queued < 1 ||
        queued > 16 ||
        span > 5000000) {
      return null;
    }
    return '倍速排期核对：video=${timing[1]} audio=${timing[2]} timer=${timing[3]} '
        'delay=${timing[4]} ao=${timing[5]} vspeed=${timing[6]} aspeed=${timing[7]} '
        'correction=${timing[8]} duration_ns=$duration queued=$queued span_us=$span；'
        '当前主循环采样，非原子音画读数或物理呈现；未改变时钟与排期';
  }
  final present = RegExp(
    r'^Yingyu present149 window_us=(\d{1,12}) frames=(\d{1,5}) '
    r'admitted=(\d{1,5}) dropped=(\d{1,5}) queue_late=(\d{1,5}) '
    r'vo_late=(\d{1,5}) gap_max_us=(\d{1,12}) age_max_us=(\d{1,12}) '
    r'late_max_us=(\d{1,12})$',
  ).firstMatch(text.trim());
  if (prefix == 'vo/gpu' && present != null) {
    final v = [for (var i = 1; i <= 9; i++) int.parse(present[i]!)];
    if (v[0] < 2000000 ||
        v[0] > 5000000 ||
        v[1] < 1 ||
        v[1] > 10000 ||
        v[2] + v[3] != v[1] ||
        v[4] + v[5] != v[3] ||
        v[6] > 5000000 ||
        v[7] > 5000000 ||
        v[8] > 30000000) {
      return null;
    }
    return '呈现队列观察：窗口=${v[0]} us；新画面=${v[1]}；准入=${v[2]}；'
        '截止前丢弃=${v[3]}；排队时已晚=${v[4]}；进入后过期=${v[5]}；'
        '提交间隔最高=${v[6]} us；排队驻留最高=${v[7]} us；过期最高=${v[8]} us；'
        '排队前包含解码、复制和主循环，非单一解码耗时；提交非物理屏幕呈现';
  }
  final release = RegExp(
    r'^(?:(?:hevc|h264|mpeg2|mpeg4|vp8|vp9|av1)_mediacodec: )?'
    r'Yingyu release(147|153) active=([01]) capacity=(2|4)$',
  ).firstMatch(text.trim());
  if (prefix == 'ffmpeg/video' &&
      release != null &&
      ((release[1] == '147' && release[3] == '2') ||
          (release[1] == '153' && release[3] == '4'))) {
    return release[2] == '1'
        ? '倍速复制输出已分离缓冲区归还；最多持有${release[3]}个编号；非实际帧率验收'
        : '倍速缓冲区归还工作器不可用，保留原同步路径';
  }
  final nonref = RegExp(
    r'^(?:hevc_mediacodec: )?Yingyu nonref145 packets=(\d{1,18})$',
  ).firstMatch(text.trim());
  if (prefix == 'ffmpeg/video' && nonref != null) {
    final count = int.tryParse(nonref[1]!);
    if (count == null || count <= 0) return null;
    return '倍速非参考画面处理：累计跳过=$count；仅已核对的 HEVC 非参考画面（追赶时含有界提前处理）；'
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
    r'^(?:https?: )?Yingyu body144 window_us=(\d{1,18}) calls=(\d{1,18}) ok=(\d{1,18}) '
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

// YY169-BEGIN
String? _probe169StageMessage(String prefix, String text) {
  if (text.length > 512 || !text.contains('Yingyu probe169 ')) return null;
  final m = RegExp(
    r'^(?:(?:hevc|h264|mpeg2|mpeg4|vp8|vp9|av1)_mediacodec: )?'
    r'Yingyu probe169 layer=(codec|queue|player) win_us=(\d{1,12}) '
    r'a=(\d{1,10}) b=(\d{1,10}) c=(\d{1,10}) d=(\d{1,10}) '
    r'max_us=(\d{1,12}) gap_us=(\d{1,12}) '
    r'head_ms=(-?\d{1,12}) tail_ms=(-?\d{1,12}) target_ms=(-?\d{1,12}) '
    r'depth=(\d{1,4}) flags=(\d{1,2}) tag=(\d{1,10})$',
  ).firstMatch(text.trim());
  if (m == null) return null;
  final layer = m[1]!;
  final expectedPrefix = {
    'codec': 'ffmpeg/video',
    'queue': 'vd',
    'player': 'cplayer',
  }[layer];
  if (prefix != expectedPrefix ||
      (layer != 'codec' &&
          text.trim().startsWith(RegExp(r'\w+_mediacodec:')))) {
    return null;
  }
  final v = [for (var i = 2; i <= 14; i++) int.parse(m[i]!)];
  if (v[0] < 2000000 ||
      v.sublist(1, 5).any((n) => n > 4294967295) ||
      v.sublist(1, 5).every((n) => n == 0) ||
      v.sublist(7, 10).any((n) => n < -1) ||
      v[10] > 1024 ||
      v[11] > 7 ||
      v[12] > 2147483647 ||
      (layer == 'queue' && v[12] > 256) ||
      (layer == 'player' && (v[12] <= 1000 || v[12] > 3000))) {
    return null;
  }
  final meaning = switch (layer) {
    'codec' => 'a=复制/包装成功 b=复制前丢弃 c=空轮询 d=保留；tag=解码代次',
    'queue' => 'a=解码返回成功 b=暂缺输出 c=结束 d=错误；tag=原队列等待阈值',
    _ => 'a=候选就绪 b=等待 c=继续处理 d=结束/错误；tag=倍速千分值',
  };
  return '卡帧边界核对：layer=$layer win_us=${v[0]} a=${v[1]} b=${v[2]} '
      'c=${v[3]} d=${v[4]} max_us=${v[5]} gap_us=${v[6]} '
      'head_ms=${v[7]} tail_ms=${v[8]} target_ms=${v[9]} '
      'depth=${v[10]} flags=${v[11]} tag=${v[12]}；$meaning；'
      '时间戳-1表示未知；player的target为音频位置，其余为复制截止；'
      '仅诊断采样，跨倍速/定位窗口不混算，非物理呈现或同步验收';
}

// YY169-END
