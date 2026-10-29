import '../core/models.dart';

/// MPV vd_lavc can emit this while trying a hardware decoder, then initialize
/// its software decoder in the same load. Keep the diagnostic and wait for an
/// actual output frame, terminal failure, or a bounded recovery deadline.
bool decoderMayFallback(String message) =>
    message.trim() == 'Could not open codec.';

/// Matches the fixed media_kit 1.2.6 error-stream sources, preserving the prefix
/// so an audio or network error cannot be mistaken for a video decoder retry.
bool isMpvErrorLog(String prefix, String level, String text) =>
    level == 'error' &&
    text.trim().isNotEmpty &&
    !isTransportReadEof(prefix, level, text) &&
    !isTransportReadTimeout(prefix, level, text) &&
    !isTransportConnectionAbort(prefix, level, text) &&
    (const {'file', 'vd', 'ad', 'cplayer', 'stream'}.contains(prefix) ||
        prefix == 'ffmpeg' && text.startsWith('tcp:'));

/// Fixed categories preserve the reason without logging internal URLs, paths
/// or tokens. A leading blank line in MPV's multi-line error is not a failure.
String? mpvOpenFailure(String prefix, String text) {
  if (prefix != 'stream') return null;
  if (text.contains(
    'Refusing to load potentially unsafe URL from a playlist.',
  )) {
    return '播放内核拒绝播放列表中的读取通路：入口类型不兼容';
  }
  if (text.contains('No protocol handler found to open URL')) {
    return '播放内核未找到该读取通路的处理接口';
  }
  return null;
}

/// AVERROR_EOF = -MKTAG('E','O','F',' ') = -541478725 = 0xdfb9b0bb.
/// This exact low-level read result does not establish that playback ended.
/// Do not generalize to timeouts, HTTP errors or other FFmpeg error codes.
bool isTransportReadEof(String prefix, String level, String text) =>
    prefix == 'ffmpeg' &&
    level == 'error' &&
    RegExp(
      r'^tcp: ffurl_read returned 0xdfb9b0bb$',
      caseSensitive: false,
    ).hasMatch(text.trim());

/// ETIMEDOUT (-110) is logged before fixed MPV/FFmpeg's existing HTTP
/// reconnect loop finishes. Only this exact read result is provisional.
/// Native end-file and premature EOF still determine a terminal failure.
bool isTransportReadTimeout(String prefix, String level, String text) =>
    prefix == 'ffmpeg' &&
    level == 'error' &&
    RegExp(
      r'^tcp: ffurl_read returned 0xffffff92$',
      caseSensitive: false,
    ).hasMatch(text.trim());

/// Android ECONNABORTED = 103. A TLS read or request-write diagnostic can
/// arrive inside the fixed HTTP reconnect loop, before its final outcome.
/// Keep the warning; native terminal events and health deadlines still fail.
bool isTransportConnectionAbort(String prefix, String level, String text) =>
    prefix == 'ffmpeg' &&
    level == 'error' &&
    RegExp(
      r'^tcp: ffurl_(?:read|write) returned 0xffffff99$',
      caseSensitive: false,
    ).hasMatch(text.trim());

bool prematureMediaEnd(Duration position, Duration duration) =>
    duration > const Duration(seconds: 3) &&
    position >= Duration.zero &&
    position < duration - const Duration(seconds: 3);

/// Exact messages from the pinned MPV/FFmpeg. Never return the native text:
/// even error messages may contain media URLs, codec vendor data or paths.
String _nativeVideoMessage(String text) =>
    text.trim().toLowerCase().replaceFirst(
      RegExp(
        r'^(?:hevc|h264|mpeg4|mpeg2|mpeg2video|vp8|vp9|av1)(?:_mediacodec)?: ',
      ),
      '',
    );

String? fixedNativeVideoReason(String text) => switch (_nativeVideoMessage(
  text,
)) {
  'egl failed to initialize.' => 'EGL显示初始化失败',
  'could not create egl surface!' => 'EGL窗口表面创建失败',
  'failed to set context!' => 'EGL上下文绑定失败',
  'could not create egl context for gles 2.x +!' => 'EGL GLES上下文创建失败',
  'could not create egl context for desktop opengl!' => 'EGL桌面OpenGL上下文创建失败',
  'failed to configure context' => 'MediaCodec输出格式解析失败',
  'output mediaformat is not set' => 'MediaCodec未提供输出格式',
  'output color format is not supported' => 'MediaCodec输出颜色格式不支持',
  'unsupported or unknown profile' => 'MediaCodec编码Profile未识别或不支持',
  'p010 negotiation rejected; using compatible output' => 'P010协商被拒绝，内核改试兼容输出',
  'dolby mapping requires raw gpu output' => '当前杜比解码候选未取得原始YUV GPU交接能力',
  _ => null,
};

/// Small, fixed startup facts from verbose codec selection, never packet logs.
/// The subscription is already bounded by OpeningLogs; dedup also bounds export.
class OpeningVideoTrace {
  final _seen = <String>{};
  void clear() => _seen.clear();
  String? add(String prefix, String text) {
    if (prefix != 'vd' && !RegExp(r'^ffmpeg/video(?:/|$)').hasMatch(prefix)) {
      return null;
    }
    String? reason = fixedNativeVideoReason(text);
    final value = text.trim();
    if (prefix == 'vd') {
      if (value == 'Using software decoding.') {
        reason = '内核正在尝试软件解码候选，最终输出仍需核对';
      } else {
        for (final codec in [
          'hevc',
          'h264',
          'mpeg4',
          'mpeg2video',
          'vp8',
          'vp9',
          'av1',
        ]) {
          for (final method in ['mediacodec', 'mediacodec-copy']) {
            final candidate = '${codec}_mediacodec-$method';
            if (value == 'Trying hardware decoding via $candidate.') {
              reason = '内核正在尝试$codec/$method候选';
            }
          }
        }
      }
    }
    if (reason == null || _seen.length >= 24 || !_seen.add(reason)) return null;
    return reason;
  }
}

/// Fixed categories only: GPU/decoder logs can contain paths and media names.
/// These diagnostics never suppress an error or change playback decisions.
class VideoDiagnostics {
  final _seen = <String>{};
  void clear() => _seen.clear();
  String? add(String prefix, String level, String text) {
    if (!const {'warn', 'error', 'fatal'}.contains(level) ||
        !RegExp(r'^(vo|vd|ffmpeg/video)(/|$)').hasMatch(prefix)) {
      return null;
    }
    final lower = _nativeVideoMessage(text);
    final status = RegExp(
      r'\bstatus\s*=\s*(-?\d{1,11})\b',
    ).firstMatch(lower)?.group(1);
    final specific =
        fixedNativeVideoReason(lower) ??
        switch (lower) {
          'both surface and native_window are null' => '解码器未取得 Surface 或原生窗口',
          "system doesn't support setinputsurface" => '系统不支持编码器输入 Surface',
          _ =>
            lower.contains('failed to configure codec')
                ? 'MediaCodec 配置失败'
                : lower.contains('failed to start codec')
                ? 'MediaCodec 启动失败'
                : lower.contains(
                    'decoder is flushing and cannot accept new buffer',
                  )
                ? '解码器刷新中拒绝新输入'
                : lower.contains('could not copy back hardware decoded frame')
                ? '硬解帧复制失败'
                : null,
        };
    final kind =
        specific ??
        (lower ==
                'discarding obsolete dolby hardware frame after decoder flush.'
            ? '定位后旧代杜比画面已丢弃，等待当前画面'
            : lower.contains('could not find ref with poc') ||
                  lower.contains('missing reference picture') ||
                  lower.contains('reference picture missing')
            ? '视频参考帧缺失'
            : lower.startsWith(
                    'attempting next decoding method after failure of ',
                  ) &&
                  lower.contains('mediacodec')
            ? 'MediaCodec 失败，内核正切换后备解码'
            : lower.contains('input packet is missing pts')
            ? '视频输入包缺少时间戳（PTS）'
            : lower.contains('non-monoton') || lower.contains('invalid pts')
            ? '视频时间戳无效或不连续'
            : lower.contains('dequeue') &&
                  (lower.contains('fail') || lower.contains('error'))
            ? '解码输出缓冲取出失败'
            : lower.contains('queueinput') &&
                  (lower.contains('fail') || lower.contains('error'))
            ? '解码输入缓冲提交失败'
            : lower.contains('shader')
            ? '着色器警告'
            : lower.contains('egl') || lower.contains('opengl')
            ? '图形上下文警告'
            : lower.contains('surface') || lower.contains('texture')
            ? '画面表面或纹理警告'
            : lower.contains('mediacodec') || lower.contains('hardware')
            ? '硬件解码警告'
            : lower.contains('format')
            ? '视频格式警告'
            : lower.contains('codec') || lower.contains('decode')
            ? '视频解码警告'
            : '视频输出警告');
    final area = prefix.split('/').first;
    final result = '$area/$level：$kind${status == null ? "" : "；状态码=$status"}';
    return _seen.add(result) ? result : null;
  }
}

/// Keep a few fixed error categories, never native URLs, headers or tokens.
/// Log messages are evidence for a failure, not a new source of fatal events.
class PlaybackDiagnostics {
  final _recent = <String>[];

  void clear() => _recent.clear();

  bool add(String prefix, String level, String text) {
    if (!const {'warn', 'error', 'fatal'}.contains(level)) return false;
    if (!RegExp(r'^(ffmpeg|stream|file|cplayer|lavf)(/|$)').hasMatch(prefix)) {
      return false;
    }
    final lower = text.toLowerCase();
    final status = RegExp(
      r'\bHTTP(?:\s+error|\s+status(?:\s+code)?|/\d(?:\.\d)?)?\s*[:=]?\s+([45]\d\d)\b',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    final String? detail;
    if (status != null) {
      detail = switch (status) {
        '401' => 'HTTP 401：媒体请求未获授权',
        '403' => 'HTTP 403：媒体服务器拒绝访问',
        '404' => 'HTTP 404：媒体地址不存在',
        '410' => 'HTTP 410：媒体地址已失效',
        '429' => 'HTTP 429：媒体请求受到限流',
        _ => 'HTTP $status：媒体服务器返回错误',
      };
    } else if (lower.contains('certificate') &&
        (lower.contains('fail') ||
            lower.contains('invalid') ||
            lower.contains('verify'))) {
      detail = 'TLS 证书校验失败';
    } else if ((lower.contains('tls') || lower.contains('ssl')) &&
        (lower.contains('fail') || lower.contains('error'))) {
      detail = 'TLS 安全连接失败';
    } else if (lower.contains('resolve') &&
        (lower.contains('fail') || lower.contains('could not'))) {
      detail = '媒体主机名称解析失败';
    } else if (lower.contains('timed out') || lower.contains('timeout')) {
      detail = '媒体网络请求超时';
    } else if (lower.contains('connection refused')) {
      detail = '媒体服务器拒绝连接';
    } else if (lower.contains('network is unreachable') ||
        lower.contains('no route to host')) {
      detail = '当前网络无法到达媒体服务器';
    } else if (lower.contains('redirect') &&
        (lower.contains('too many') || lower.contains('fail'))) {
      detail = '媒体地址重定向失败';
    } else {
      detail = null;
    }
    if (detail == null || _recent.contains(detail)) return false;
    _recent.add(detail);
    if (_recent.length > 3) _recent.removeAt(0);
    return true;
  }

  String describe(Object error) {
    final message = safeError(error);
    if (_recent.isEmpty) return message;
    return '${message.length > 260 ? '${message.substring(0, 260)}…' : message}'
        '\n网络诊断：${_recent.join('；')}';
  }
}

/// Stage names come from the active output transaction, never a guessed timer.
String? hdrLoadingMessage(String stage) {
  if (stage.startsWith('restore-')) return 'HDR 未就绪，正在恢复兼容画面';
  if (stage.startsWith('option-') || stage == 'detach' || stage == 'surface') {
    return '正在配置 HDR 显示';
  }
  return switch (stage) {
    'snapshot' => '正在校验 HDR 条件',
    'hdr-video' || 'hdr-refill' => '正在准备 HDR 画面',
    'hdr-frame' => '正在等待 HDR 首帧',
    'hdr-ready' => 'HDR 已就绪，正在衔接播放',
    'compatible-ready' => '兼容画面已恢复，正在衔接播放',
    _ => null,
  };
}
