import 'dart:convert';
import '../core/models.dart';

/// Only selected, decoded Dolby5/7 uses the optional in-place path. Server
/// labels and ordinary HDR never opt in to this change.
bool useDolbyEnhancement(Map<String, String> decoded, String vo) =>
    vo == 'gpu-next' &&
    const {'5', '7'}.contains(decoded['dolby-vision-profile']);

bool enhancementRenderError(String prefix, String level, String text) =>
    prefix.startsWith('vo') &&
    const {'error', 'fatal'}.contains(level) &&
    (text.toLowerCase().contains('shader') ||
        text.contains('Failed creating render pass') ||
        text.contains('Failed dispatching hook') ||
        text.contains('User hook tried resizing non-resizable stage!') ||
        text.contains('Failed executing hook, disabling') ||
        text.contains('Failed rendering frame'));

class EnhancementRenderProof {
  const EnhancementRenderProof(this.frame, this.valid, this.shader);
  final int frame;
  final bool valid;
  final String shader;

  static EnhancementRenderProof parse(String raw) {
    if (raw.length > 1024) throw const FormatException();
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['frame'] is! int ||
        (value['frame'] as int) < 0 ||
        value['valid'] is! bool ||
        value['shader'] is! String ||
        !RegExp(r'^(?:[a-f0-9]{64})?$').hasMatch(value['shader'] as String)) {
      throw const FormatException();
    }
    return EnhancementRenderProof(
      value['frame'] as int,
      value['valid'] as bool,
      value['shader'] as String,
    );
  }
}

/// Each property write has its own before-frame snapshot, including rollback.
/// The VO publishes proof only after rendering AND swapchain submission.
class DolbyEnhancementConfirmation {
  DolbyEnhancementConfirmation({
    required this.read,
    required this.active,
    required this.renderFault,
    this.timeout = const Duration(milliseconds: 1500),
  });
  final Future<String> Function(String) read;
  final bool Function() active;
  final int Function() renderFault;
  final Duration timeout;
  int? _beforeFrame;
  int _fault = 0;

  Future<void> prepare() async {
    _beforeFrame = null;
    if (!active()) throw const AppFailure('播放会话已改变');
    final raw = await read('yingyu-enhancement-state').timeout(timeout);
    if (!active()) throw const AppFailure('播放会话已改变');
    try {
      _beforeFrame = EnhancementRenderProof.parse(raw).frame;
    } catch (_) {
      throw const AppFailure('当前画面渲染状态未确认，已保留先前设置');
    }
    _fault = renderFault();
  }

  Future<void> confirm(String path) {
    final before = _beforeFrame;
    if (before == null) throw const AppFailure('画面增强缺少本次渲染基线');
    return confirmDolbyEnhancement(
      path: path,
      afterFrame: before,
      read: read,
      active: active,
      renderFailed: () => renderFault() != _fault,
      timeout: timeout,
    );
  }
}

/// Historical fresh/redraw performance descriptions never confirm an update.
Future<void> confirmDolbyEnhancement({
  required String path,
  int afterFrame = 0,
  required Future<String> Function(String) read,
  required bool Function() active,
  required bool Function() renderFailed,
  Duration timeout = const Duration(milliseconds: 1500),
}) async {
  final match = RegExp(r'([a-f0-9]{64})\.hook$').firstMatch(path);
  if (path.isNotEmpty && match == null) throw const AppFailure('画面增强文件未确认');
  final expected = path.isEmpty ? '' : match![1]!;
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    if (!active()) throw const AppFailure('播放会话已改变');
    if (renderFailed()) throw const AppFailure('画面增强渲染失败，已恢复先前设置');
    try {
      final raw = await read(
        'yingyu-enhancement-state',
      ).timeout(timeout - clock.elapsed);
      if (!active()) throw const AppFailure('播放会话已改变');
      if (renderFailed()) throw const AppFailure('画面增强渲染失败，已恢复先前设置');
      final proof = EnhancementRenderProof.parse(raw);
      if (proof.valid && proof.frame > afterFrame && proof.shader == expected) {
        return;
      }
    } on AppFailure {
      rethrow;
    } catch (_) {
      // An unavailable sample remains unconfirmed; never assume success.
    }
    await Future<void>.delayed(const Duration(milliseconds: 32));
  }
  throw const AppFailure('画面增强未通过渲染核对，已恢复先前设置');
}
