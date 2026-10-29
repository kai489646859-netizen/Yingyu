import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Local declarations and the established output are separate facts. This
/// snapshot is also used by the information panel, without a probe or timer.
class OutputCapabilities {
  const OutputCapabilities({
    this.sdk = 0,
    this.display,
    this.maxLuminance = 0,
    this.hdr = const {},
    this.anticipatedAudio = const {},
  });
  final int sdk;
  final double maxLuminance;
  final int? display;
  final Set<int> hdr, anticipatedAudio;
  factory OutputCapabilities.parse(Map<dynamic, dynamic> value) {
    Set<int> ints(Object? v) => v is List ? v.whereType<int>().toSet() : {};
    return OutputCapabilities(
      sdk: value['sdk'] is int ? value['sdk'] as int : 0,
      display: value['display'] is int ? value['display'] as int : null,
      maxLuminance:
          value['hdrMaxLuminance'] is num &&
              (value['hdrMaxLuminance'] as num).isFinite &&
              (value['hdrMaxLuminance'] as num) >= 80 &&
              (value['hdrMaxLuminance'] as num) <= 10000
          ? (value['hdrMaxLuminance'] as num).toDouble()
          : 0,
      hdr: ints(value['hdrTypes']),
      anticipatedAudio: ints(value['anticipatedAudioTypes']),
    );
  }
  String get displayDescription {
    final labels = [
      if (hdr.contains(2)) 'HDR10',
      if (hdr.contains(3)) 'HLG',
      if (hdr.contains(4)) 'HDR10+',
      if (hdr.contains(1)) '杜比视界',
    ];
    return display == null
        ? '未取得当前屏幕能力'
        : labels.isEmpty
        ? '当前屏幕未声明 HDR'
        : '${labels.join(' / ')}（屏幕声明）';
  }

  String get audioDescription {
    const types = {
      1: '听筒',
      2: '扬声器',
      3: '有线耳机',
      4: '有线耳机',
      7: '蓝牙',
      8: '蓝牙',
      9: 'HDMI',
      10: 'HDMI',
      11: 'USB',
      12: 'USB',
      13: '扩展坞',
      19: '辅助输出',
      22: 'USB',
      23: '助听设备',
      26: '蓝牙',
      27: '蓝牙',
      29: 'HDMI',
      30: '蓝牙',
    };
    final labels = anticipatedAudio.map((t) => types[t] ?? '其他设备').toSet();
    return labels.isEmpty ? '系统媒体路由未提供' : '${labels.join(' / ')}（系统预期路由）';
  }
}

enum DetectedVideoRange { unknown, sdr, hdr10, hlg, dolby }

/// Inspect the selected native track and decoded frame first. Server labels
/// do not override these observations, and missing profile data is not zero.
DetectedVideoRange detectVideoRange(
  Map<String, String> decoded,
  String profile,
) {
  final dv = int.tryParse(profile);
  if (dv != null && dv > 0 && dv <= 10 ||
      decoded['video-params/colormatrix'] == 'dolbyvision') {
    return DetectedVideoRange.dolby;
  }
  if (dv != 0) return DetectedVideoRange.unknown;
  if (decoded['video-params/primaries'] == 'bt.2020') {
    if (decoded['video-params/gamma'] == 'pq') return DetectedVideoRange.hdr10;
    if (decoded['video-params/gamma'] == 'hlg') return DetectedVideoRange.hlg;
  }
  return const {
        'bt.1886',
        'srgb',
        'gamma2.2',
        'gamma2.4',
        'bt.709',
      }.contains(decoded['video-params/gamma'])
      ? DetectedVideoRange.sdr
      : DetectedVideoRange.unknown;
}

/// Detection and output eligibility are separate: a real HDR source still
/// needs a compatible current Display, container and native Surface contract.
bool supportedHdrContainer(String container) => const {
  'mkv',
  'matroska',
  'matroska,webm',
  'mov,mp4,m4a,3gp,3g2,mj2',
  'mov',
  'mp4',
  'webm',
}.contains(container.trim().toLowerCase());

String? nativeHdrTransfer({
  required bool requested,
  required bool disc,
  required DetectedVideoRange source,
  required String container,
  required OutputCapabilities capabilities,
}) {
  if (!requested ||
      disc ||
      capabilities.sdk < 33 ||
      capabilities.display == null ||
      !supportedHdrContainer(container)) {
    return null;
  }
  return source == DetectedVideoRange.hdr10 && capabilities.hdr.contains(2)
      ? 'pq'
      : source == DetectedVideoRange.hlg && capabilities.hdr.contains(3)
      ? 'hlg'
      : null;
}

abstract class PlaybackOutputBackend {
  String get outputDescription;
  OutputCapabilities get outputCapabilities;
}

typedef HdrSurfaceWriter =
    Future<bool> Function({
      required int token,
      required int width,
      required int height,
      required String transfer,
      required bool fill,
    });

/// One optional-window recovery per media. Only the exact related VO errors
/// are held while its owned SDR restoration runs. Real terminal, transport,
/// metadata-pairing, audio and unrelated decoder failures remain authoritative.
class DolbyHdrRecovery {
  bool recovering = false, rejected = false;
  int _generation = 0;
  void reset() {
    ++_generation;
    recovering = false;
    rejected = false;
  }

  bool holdsInitializationError(String prefix, String text) =>
      recovering &&
      (prefix.startsWith('vo') || prefix == 'cplayer') &&
      const {
        'Failed to initialize video output',
        'Error opening/initializing the selected video_out (--vo) device.',
        'Failed initializing any suitable GPU context!',
      }.contains(text.trim());

  Future<void> reject({
    required Future<void> Function() restore,
    required bool Function() current,
    required void Function() restored,
    required void Function() failure,
  }) async {
    if (recovering || rejected) return;
    final generation = _generation;
    recovering = true;
    rejected = true;
    try {
      await restore();
      if (generation == _generation && current()) restored();
    } catch (_) {
      if (generation == _generation && current()) failure();
    } finally {
      if (generation == _generation) recovering = false;
    }
  }
}

class NativeHdrAdapter {
  NativeHdrAdapter({
    required this.write,
    required this.active,
    required this.message,
    required this.failure,
    this.detach,
    this.preloadedWrite,
    this.verifyPreloaded,
  }) {
    _owners[owner] = this;
    _channel.setMethodCallHandler(_receive);
  }
  final HdrSurfaceWriter write;
  final HdrSurfaceWriter? preloadedWrite;
  final Future<bool> Function()? verifyPreloaded;
  final Future<void> Function()? detach;
  final bool Function() active;
  final void Function(String) message, failure;
  static const _channel = MethodChannel('yingyu/native_hdr');
  static final _owners = <int, NativeHdrAdapter>{};
  static int _nextOwner = 1;
  final int owner = _nextOwner++;
  final request = ValueNotifier<String?>(null);
  OutputCapabilities capabilities = const OutputCapabilities();
  Future<void> _tail = Future.value();
  Completer<Map<dynamic, dynamic>?>? _first;
  Map<dynamic, dynamic>? _surface;
  bool _started = false,
      _closed = false,
      _attempted = false,
      _established = false;
  Future<void>? _starting;
  Future<void>? _closing;
  bool _fill = false;
  int _changing = 0;
  bool get changing => _changing != 0;
  String status = 'not-attempted';
  int? _display;
  int _token = 0;
  String? _transfer;
  bool get established => _established;
  bool _autoDolby = false, _warming = false;
  int _warmSerial = 0;
  String _preparedTransfer = 'pq';
  bool _hlgOnly = false, _deferHlg = false;
  bool _dolbyPreparing = false, _postDolby = false;
  bool _needsReleaseFrame = false;
  bool get dolbyEstablished => _established && (_autoDolby || _postDolby);
  String get dolbyHdrLabel =>
      _transfer == 'hlg' ? '杜比映射 HLG HDR' : '杜比映射 HDR10';
  Future<void>? _warmPending;
  Completer<void>? _warmCancelled;
  Map<dynamic, dynamic>? _warmReady;
  bool get autoDolby => _autoDolby;
  bool get autoArmed => _autoDolby && _token > 0 && !_established;
  HdrSurfaceWriter get _writer => _autoDolby ? preloadedWrite! : write;
  String get description => _established
      ? '原生 ${_transfer == 'pq' ? 'PQ' : 'HLG'} / BT.2020 / 10 位通路'
      : 'SDR 兼容显示';

  Future<T> _run<T>(Future<T> Function() action) {
    final result = _tail.then((_) async {
      _changing++;
      try {
        return await action();
      } finally {
        _changing--;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static Future<void> _receive(MethodCall call) async {
    if (call.arguments is! Map) return;
    final value = call.arguments as Map;
    final target = _owners[value['owner']];
    if (target == null || target._closed) return;
    if (call.method == 'surface') {
      final retired = value['retiredToken'];
      if (value['token'] == 0 &&
          retired is int &&
          retired > 0 &&
          target._surface?['token'] != retired) {
        return;
      }
      target._surface = value;
      final token = value['token'],
          width = value['width'],
          height = value['height'];
      if (target._first?.isCompleted == false &&
          (token == 0 ||
              (token is int &&
                  token > 0 &&
                  width is int &&
                  width > 1 &&
                  height is int &&
                  height > 1))) {
        target._first!.complete(token == 0 ? null : value);
      } else if (target._established || target.autoArmed) {
        unawaited(
          target
              ._run<void>(() async {
                if (target._closed ||
                    (!target._established && !target.autoArmed)) {
                  return;
                }
                if (token == 0 ||
                    token != target._token ||
                    target._surface != value ||
                    OutputCapabilities.parse(value).display !=
                        target._display ||
                    !OutputCapabilities.parse(
                      value,
                    ).hdr.contains(target._transfer == 'pq' ? 2 : 3)) {
                  if (target._surface == value) await target._fallback();
                  return;
                }
                await target._resize();
              })
              .catchError((Object _) => target.failure('HDR 显示恢复失败，已保留观看进度')),
        );
      }
    } else if (call.method == 'changed') {
      final next = OutputCapabilities.parse(value);
      final old = target.capabilities;
      target.capabilities = next;
      if (value['kind'] == 'audio' &&
          !setEquals(old.anticipatedAudio, next.anticipatedAudio)) {
        target.message(
          '音频路由变化：${next.audioDescription}；继续兼容 PCM 输出，当前 AO 路由未单独确认',
        );
      }
      if ((target._established || target.autoArmed) &&
          (next.display != target._display ||
              !next.hdr.contains(target._transfer == 'pq' ? 2 : 3))) {
        unawaited(
          target
              ._run(target._fallback)
              .catchError((Object _) => target.failure('HDR 显示恢复失败，已保留观看进度')),
        );
      }
    }
  }

  Future<void> start() => _starting ??= _start();

  /// Preparation starts alongside demuxing. The Dolby preloaded hook can join
  /// only this bounded local attempt, before a decoder/output has been chosen.
  Future<void> warmDolby({bool deferHlg = false}) {
    _deferHlg = _deferHlg || deferHlg;
    if (_warming) return _warmPending ?? Future<void>.value();
    return _warmPending = _warmDolby();
  }

  void _warmResult(String reason) {
    status = 'dolby-hdr-$reason';
    message(
      '[HDR180] candidate=$reason; sdk=${capabilities.sdk}; '
      'display=${capabilities.display == null ? "unknown" : "known"}; '
      'hdr10=${capabilities.hdr.contains(2)}; hlg=${capabilities.hdr.contains(3)}',
    );
  }

  Future<void> _warmDolby() async {
    if (_closed ||
        _warming ||
        _warmReady != null ||
        _attempted ||
        preloadedWrite == null ||
        verifyPreloaded == null) {
      return;
    }
    final serial = ++_warmSerial;
    _warming = true;
    _warmCancelled = Completer<void>();
    status = 'dolby-hdr-capability-pending';
    bool current() => !_closed && serial == _warmSerial && active();
    try {
      await start();
      if (!current()) return;
      if (capabilities.sdk < 33 || capabilities.display == null) {
        _warmResult(
          capabilities.sdk == 0 || capabilities.display == null
              ? 'capability-unavailable'
              : 'sdk-unsupported',
        );
        return;
      }
      final transfers = [
        if (!_hlgOnly && capabilities.hdr.contains(2)) 'pq',
        if (capabilities.hdr.contains(3) &&
            (!_deferHlg || !capabilities.hdr.contains(2)))
          'hlg',
      ];
      if (transfers.isEmpty) {
        _warmResult('hdr10-unsupported');
        return;
      }
      for (final transfer in transfers) {
        if (!current()) return;
        try {
          status = 'dolby-hdr-$transfer-surface-pending';
          var surface = _surface;
          final reusable =
              request.value != null &&
              surface?['token'] is int &&
              (surface!['token'] as int) > 0 &&
              surface['width'] is int &&
              (surface['width'] as int) > 1 &&
              surface['height'] is int &&
              (surface['height'] as int) > 1;
          if (!reusable) {
            final first = Completer<Map<dynamic, dynamic>?>();
            _first = first;
            request.value = transfer;
            surface = await Future.any<Map<dynamic, dynamic>?>(
              [first.future, _warmCancelled!.future.then((_) => null)],
            ).timeout(const Duration(milliseconds: 500), onTimeout: () => null);
            if (identical(_first, first)) _first = null;
          } else {
            request.value = transfer;
          }
          if (!current()) return;
          if (surface == null) {
            _warmResult('$transfer-surface-unavailable');
            continue;
          }
          final local = OutputCapabilities.parse(surface);
          if (local.display != capabilities.display ||
              !local.hdr.contains(transfer == 'pq' ? 2 : 3)) {
            _warmResult('$transfer-surface-capability');
            continue;
          }
          status = 'dolby-hdr-$transfer-probe-pending';
          final probe = await _channel
              .invokeMapMethod<dynamic, dynamic>('probe', {
                'owner': owner,
                'token': surface['token'],
                'transfer': transfer,
              })
              .timeout(const Duration(milliseconds: 1000));
          if (!current()) return;
          if (probe?['status'] == 'ready' &&
              _surface?['token'] == surface['token'] &&
              capabilities.display == local.display &&
              capabilities.hdr.contains(transfer == 'pq' ? 2 : 3)) {
            _preparedTransfer = transfer;
            _warmReady = surface;
            _warmResult('$transfer-prepared');
            return;
          }
          const allowed = {
            'surface-unavailable',
            'transfer-invalid',
            'worker-context-busy',
            'egl-display',
            'egl-colorspace',
            'egl-hdr-transfer',
            'rgb10-config',
            'egl-api',
            'egl-context',
            'egl-window',
            'surface-colorspace',
            'egl-current',
            'egl-exception',
            'probe-busy',
            'dataspace-library',
            'dataspace-symbols',
            'dataspace-set',
            'dataspace-readback',
            'buffer-format',
          };
          final reason = probe?['status'];
          _warmResult(
            '$transfer-probe-${reason is String && allowed.contains(reason) ? reason : "not-confirmed"}',
          );
        } on TimeoutException {
          if (current()) _warmResult('$transfer-probe-timeout');
        } catch (_) {
          if (current()) _warmResult('$transfer-platform-unavailable');
        }
      }
    } finally {
      if (serial == _warmSerial) {
        _warming = false;
        if (_warmReady == null && !_closed) {
          _needsReleaseFrame = _needsReleaseFrame || request.value != null;
          request.value = null;
        }
      }
    }
  }

  void cancelWarm() {
    if (_warmCancelled?.isCompleted == false) _warmCancelled!.complete();
    ++_warmSerial;
    if (_warming && _first?.isCompleted == false) _first!.complete(null);
    final hadCandidate = _warming || _warmReady != null;
    _warming = false;
    _warmReady = null;
    if (hadCandidate && !_autoDolby && !_closed) request.value = null;
  }

  /// Join an in-flight local window/probe for at most two seconds. Cancellation
  /// wins immediately. No media reload, extra seek or switch after first output.
  Future<bool> claimWarm({Duration wait = const Duration(seconds: 2)}) async {
    final clock = Stopwatch()..start();
    final budget = wait > const Duration(seconds: 2)
        ? const Duration(seconds: 2)
        : wait;
    for (var attempt = 0; attempt < 2; attempt++) {
      final serial = _warmSerial,
          pending = _warmPending,
          cancelled = _warmCancelled;
      final remaining = budget - clock.elapsed;
      if (_warming && pending != null && remaining > Duration.zero) {
        await Future.any<void>([
          pending,
          if (cancelled != null) cancelled.future,
        ]).timeout(remaining, onTimeout: () {});
        if (_closed || !active() || serial != _warmSerial) return false;
        if (_warming && _warmReady == null) _warmResult('admission-deadline');
      }
      final selected = _preparedTransfer;
      final accepted = await _claimReady(serial);
      if (!_closed && active()) {
        message(
          '[HDR180] admission=${accepted ? "armed" : "sdr"}; transfer=$selected; wait_ms=${clock.elapsedMilliseconds}; reason=$status',
        );
      }
      if (accepted) return true;
      if (_closed ||
          !active() ||
          serial != _warmSerial ||
          selected != 'pq' ||
          _hlgOnly ||
          _deferHlg ||
          !capabilities.hdr.contains(3) ||
          clock.elapsed >= budget) {
        return false;
      }
      // The decoder is still held by on_preloaded. SDR restoration finished
      // before trying the second local transfer; never switch a playing frame.
      _attempted = false;
      _autoDolby = false;
      cancelWarm();
      _hlgOnly = true;
      unawaited(warmDolby());
    }
    return false;
  }

  Future<bool> _claimReady(int serial) => _run(() async {
    if (serial != _warmSerial) return false;
    final prepared = _warmReady, surface = _surface;
    if (_closed ||
        !active() ||
        _attempted ||
        prepared == null ||
        surface == null ||
        surface['token'] != prepared['token'] ||
        OutputCapabilities.parse(surface).display != capabilities.display ||
        !capabilities.hdr.contains(_preparedTransfer == 'hlg' ? 3 : 2)) {
      cancelWarm();
      return false;
    }
    _warmReady = null;
    _attempted = true;
    _autoDolby = true;
    _transfer = _preparedTransfer;
    _display = capabilities.display;
    _token = surface['token'] as int;
    final ok = await _writer(
      token: _token,
      width: surface['width'] as int,
      height: surface['height'] as int,
      transfer: _transfer!,
      fill: _fill,
    );
    if (!ok) _warmResult('output-bridge-rejected');
    if (!ok ||
        _closed ||
        serial != _warmSerial ||
        !active() ||
        _surface?['token'] != _token ||
        capabilities.display != _display ||
        !capabilities.hdr.contains(_transfer == 'hlg' ? 3 : 2)) {
      await _fallback(
        retainCandidate:
            !ok &&
            !_closed &&
            active() &&
            serial == _warmSerial &&
            _preparedTransfer == 'pq' &&
            capabilities.hdr.contains(3),
      );
      return false;
    }
    status = 'dolby-hdr-${_transfer!}-armed';
    return true;
  });

  Future<bool> confirmWarm() => _run(() async {
    if (!autoArmed || _closed || !active()) return false;
    if (await verifyPreloaded!() &&
        !_closed &&
        active() &&
        _surface?['token'] == _token &&
        capabilities.display == _display &&
        capabilities.hdr.contains(_transfer == 'hlg' ? 3 : 2)) {
      _established = true;
      status = 'dolby-hdr-${_transfer!}-ready';
      message(
        '$dolbyHdrLabel：${_transfer == 'hlg' ? 'HLG' : 'PQ'} / BT.2020 / RGB10A2 通路已建立；屏幕效果待设备验收',
      );
      return true;
    }
    await _fallback();
    return false;
  });

  /// The caller stops the old media first. Reset only the new optional mode;
  /// the existing ordinary-HDR adapter keeps its original lifetime policy.
  Future<void> abandonAuto() => _run(_fallback);

  Future<void> resetAuto() async {
    _needsReleaseFrame = _needsReleaseFrame || request.value != null;
    _hlgOnly = false;
    _deferHlg = false;
    _postDolby = false;
    cancelWarm();
    if (!_autoDolby) return;
    await _run(_fallback);
    _autoDolby = false;
    _attempted = false;
    _transfer = null;
  }

  Future<void> _start() async {
    if (_started ||
        _closed ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _started = true;
    try {
      final value = await _channel
          .invokeMapMethod<dynamic, dynamic>('watch', {'owner': owner})
          .timeout(const Duration(milliseconds: 400));
      if (!_closed && value != null) {
        capabilities = OutputCapabilities.parse(value);
      }
    } catch (_) {
      /* Capability failure never blocks compatible playback. */
    }
  }

  /// The established SDR Dolby decoder remains gpu-next. Reuse the ordinary
  /// output transaction only with that renderer and its full RGB HDR contract.
  Future<bool> prepareDolby() async {
    if (_closed || !active()) return false;
    if (_needsReleaseFrame) {
      _needsReleaseFrame = false;
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () {},
      );
      if (_closed || !active()) return false;
    }
    _dolbyPreparing = true;
    try {
      for (final transfer in [
        if (capabilities.hdr.contains(2)) 'pq',
        if (capabilities.hdr.contains(3)) 'hlg',
      ]) {
        if (_closed || !active()) return false;
        _attempted = false;
        final ready = await prepare(transfer);
        message(
          '[HDR180] decoded-Dolby transfer=$transfer; established=$ready; stage=$status',
        );
        if (ready) {
          _postDolby = true;
          return true;
        }
      }
      return false;
    } finally {
      _dolbyPreparing = false;
      if (!_established && !_closed) {
        _surface = null;
        request.value = null;
      }
    }
  }

  Future<bool> prepare(String transfer) => _run(() async {
    if (_closed || _attempted || !active()) return false;
    _attempted = true;
    _transfer = transfer;
    Map<dynamic, dynamic>? first;
    if (_dolbyPreparing &&
        _surface?['token'] is int &&
        (_surface!['token'] as int) > 0) {
      request.value = transfer;
      first = _surface;
    } else {
      _first = Completer<Map<dynamic, dynamic>?>();
      request.value = transfer;
      first = await _first!.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => null,
      );
      _first = null;
    }
    if (first == null || _closed || !active()) {
      status = 'surface-wait';
      if (!_closed) if (!_dolbyPreparing) request.value = null;
      return false;
    }
    final current = _surface;
    if (current == null || current['token'] != first['token']) {
      status = 'surface-changed';
      if (!_dolbyPreparing) request.value = null;
      return false;
    }
    final local = OutputCapabilities.parse(current);
    if (local.display != capabilities.display ||
        !local.hdr.contains(transfer == 'pq' ? 2 : 3)) {
      status = 'display-capability';
      if (!_dolbyPreparing) request.value = null;
      return false;
    }
    // Validate the separate window before touching the current, working VO.
    // A blocked EGL driver runs on a Java worker, never on the UI isolate.
    String probeStatus = 'probe-unavailable';
    try {
      final probe = await _channel
          .invokeMapMethod<dynamic, dynamic>('probe', {
            'owner': owner,
            'token': current['token'],
            'transfer': transfer,
          })
          .timeout(const Duration(milliseconds: 1000));
      const allowed = {
        'ready',
        'surface-unavailable',
        'transfer-invalid',
        'worker-context-busy',
        'egl-display',
        'egl-colorspace',
        'egl-hdr-transfer',
        'rgb10-config',
        'egl-api',
        'egl-context',
        'egl-window',
        'surface-colorspace',
        'egl-current',
        'egl-exception',
        'probe-busy',
        'dataspace-library',
        'dataspace-symbols',
        'dataspace-set',
        'dataspace-readback',
        'buffer-format',
      };
      final reported = probe?['status'];
      if (reported is String && allowed.contains(reported)) {
        probeStatus = reported;
      }
    } catch (_) {
      /* An unavailable candidate leaves the current output intact. */
    }
    status = 'window-$probeStatus';
    message('HDR 独立窗口检查：$probeStatus；只检查本次候选窗口');
    if (probeStatus != 'ready' ||
        _closed ||
        !active() ||
        _surface?['token'] != current['token'] ||
        capabilities.display != local.display ||
        !capabilities.hdr.contains(transfer == 'pq' ? 2 : 3)) {
      if (!_dolbyPreparing) request.value = null;
      return false;
    }
    _display = local.display;
    final ok = await write(
      token: current['token'] as int,
      width: current['width'] as int,
      height: current['height'] as int,
      transfer: transfer,
      fill: _fill,
    );
    _established = ok;
    status = ok ? 'output-ready' : 'output-rejected';
    _token = ok ? current['token'] as int : 0;
    if (!ok ||
        _closed ||
        !active() ||
        _surface?['token'] != current['token'] ||
        capabilities.display != _display ||
        !capabilities.hdr.contains(transfer == 'pq' ? 2 : 3)) {
      await _fallback();
      return false;
    }
    if (_surface?['width'] != current['width'] ||
        _surface?['height'] != current['height']) {
      await _resize();
      if (!_established) return false;
    }
    message('原生 HDR 通路已建立：$description；独立 Surface；物理屏幕颜色和长播仍待设备验收');
    return true;
  });

  Future<void> _resize() async {
    final surface = _surface;
    if (_closed ||
        (!_established && !autoArmed) ||
        surface == null ||
        !active()) {
      return;
    }
    final width = surface['width'], height = surface['height'];
    if (width is! int || height is! int || width <= 1 || height <= 1) return;
    if (!await _writer(
      token: surface['token'] as int,
      width: width,
      height: height,
      transfer: _transfer!,
      fill: _fill,
    )) {
      await _fallback();
    }
  }

  Future<void> _fallback({bool retainCandidate = false}) async {
    // Restore before removing the native view. Native token ownership also
    // protects asynchronous Android destruction and engine teardown.
    await _writer(
      token: 0,
      width: 1,
      height: 1,
      transfer: _transfer ?? 'pq',
      fill: false,
    );
    final wasEstablished = _established;
    _established = false;
    _token = 0;
    if (!(retainCandidate || (_dolbyPreparing && !_closed && active()))) {
      _needsReleaseFrame = _needsReleaseFrame || request.value != null;
      _surface = null;
      request.value = null;
    }
    if (wasEstablished && !_closed) message('原生 HDR 显示已结束；恢复兼容输出，本次播放不再重试');
  }

  Widget view(Widget child, BoxFit fit, {required Widget subtitles}) {
    final fill = fit == BoxFit.cover;
    if (fill != _fill) {
      _fill = fill;
      if (_established) {
        unawaited(
          _run(_resize).catchError((Object _) => failure('HDR 画面适配失败，已保留观看进度')),
        );
      }
    }
    return ValueListenableBuilder<String?>(
      valueListenable: request,
      child: child,
      builder: (context, transfer, original) => Stack(
        fit: StackFit.expand,
        children: [
          // Preserve the original picture's State and output ownership
          // while admitting, rejecting or releasing the candidate.
          Offstage(offstage: transfer != null, child: original!),
          if (transfer != null) _HdrSurface(owner: owner),
          if (transfer != null) IgnorePointer(child: subtitles),
        ],
      ),
    );
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    cancelWarm();
    _closed = true;
    if (_first?.isCompleted == false) _first!.complete(null);
    try {
      // Closing never needs to recreate a compatible renderer or wait for a
      // decoded frame. The player is about to be destroyed, not resumed.
      final release = detach;
      if (release != null) {
        // The native controller owns its own Surface lock. Reach its immediate
        // cancellation signal before waiting for our pending admission tail.
        try {
          await release();
        } finally {
          await _tail;
        }
      } else {
        await _run(_fallback);
      }
    } finally {
      _established = false;
      _token = 0;
      _surface = null;
      request.value = null;
      _owners.remove(owner);
      try {
        if (_started) {
          await _channel
              .invokeMethod('stop', {'owner': owner})
              .timeout(const Duration(milliseconds: 500));
        }
      } catch (_) {}
      request.dispose();
    }
  }
}

class _HdrSurface extends StatelessWidget {
  const _HdrSurface({required this.owner});
  final int owner;
  @override
  Widget build(BuildContext context) => PlatformViewLink(
    viewType: 'yingyu/native_hdr_surface',
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    ),
    onCreatePlatformView: (params) =>
        PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: 'yingyu/native_hdr_surface',
            layoutDirection: TextDirection.ltr,
            creationParams: {'owner': owner},
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create(),
  );
}
