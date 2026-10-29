// ignore_for_file: unused_element, curly_braces_in_flow_control_structures
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
    this.hdr = const {},
    this.anticipatedAudio = const {},
  });
  final int sdk;
  final int? display;
  final Set<int> hdr, anticipatedAudio;
  factory OutputCapabilities.parse(Map<dynamic, dynamic> value) {
    Set<int> ints(Object? v) => v is List ? v.whereType<int>().toSet() : {};
    return OutputCapabilities(
      sdk: value['sdk'] is int ? value['sdk'] as int : 0,
      display: value['display'] is int ? value['display'] as int : null,
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
      !const {
        'matroska',
        'matroska,webm',
        'mov,mp4,m4a,3gp,3g2,mj2',
        'mov',
        'mp4',
        'webm',
      }.contains(container)) {
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

class NativeHdrAdapter {
  NativeHdrAdapter({
    required this.write,
    required this.active,
    required this.message,
    required this.failure,
  }) {
    _owners[owner] = this;
    _channel.setMethodCallHandler(_receive);
  }
  final HdrSurfaceWriter write;
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
  bool _fill = false;
  int? _display;
  int _token = 0;
  String? _transfer;
  bool get established => _established;
  String get description => _established
      ? '原生 ${_transfer == 'pq' ? 'PQ' : 'HLG'} / BT.2020 / 10 位通路'
      : 'SDR 兼容显示';

  Future<T> _run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static Future<void> _receive(MethodCall call) async {
    if (call.arguments is! Map) return;
    final value = call.arguments as Map;
    final target = _owners[value['owner']];
    if (target == null || target._closed) return;
    if (call.method == 'surface') {
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
      } else if (target._established) {
        unawaited(
          target
              ._run<void>(() async {
                if (target._closed || !target._established) return;
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
      if (target._established &&
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

  Future<bool> prepare(String transfer) => _run(() async {
    if (_closed || _attempted || !active()) return false;
    _attempted = true;
    _transfer = transfer;
    _first = Completer<Map<dynamic, dynamic>?>();
    request.value = transfer;
    final first = await _first!.future.timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () => null,
    );
    _first = null;
    if (first == null || _closed || !active()) {
      if (!_closed) request.value = null;
      return false;
    }
    final current = _surface;
    if (current == null || current['token'] != first['token']) {
      request.value = null;
      return false;
    }
    final local = OutputCapabilities.parse(current);
    if (local.display != capabilities.display ||
        !local.hdr.contains(transfer == 'pq' ? 2 : 3)) {
      request.value = null;
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
    message('原生 HDR 通路已建立：$description；独立 Surface；物理屏幕颜色和长播仍待设备验收');
    return true;
  });

  Future<void> _resize() async {
    final surface = _surface;
    if (_closed || !_established || surface == null || !active()) return;
    final width = surface['width'], height = surface['height'];
    if (width is! int || height is! int || width <= 1 || height <= 1) return;
    if (!await write(
      token: surface['token'] as int,
      width: width,
      height: height,
      transfer: _transfer!,
      fill: _fill,
    )) {
      await _fallback();
    }
  }

  Future<void> _fallback() async {
    // Restore before removing the native view. Native token ownership also
    // protects asynchronous Android destruction and engine teardown.
    await write(
      token: 0,
      width: 1,
      height: 1,
      transfer: _transfer ?? 'pq',
      fill: false,
    );
    final wasEstablished = _established;
    _established = false;
    _token = 0;
    _surface = null;
    request.value = null;
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
      builder: (context, transfer, original) => transfer == null
          ? original!
          : Stack(
              fit: StackFit.expand,
              children: [
                Offstage(child: original!),
                _HdrSurface(owner: owner),
                IgnorePointer(child: subtitles),
              ],
            ),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_first?.isCompleted == false) _first!.complete(null);
    try {
      await _run(_fallback);
    } finally {
      _owners.remove(owner);
      try {
        if (_started) await _channel.invokeMethod('stop', {'owner': owner});
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
