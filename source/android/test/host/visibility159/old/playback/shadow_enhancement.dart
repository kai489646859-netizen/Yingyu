import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';
import '../core/models.dart';

abstract class ShadowEnhancementBackend {
  double get shadowEnhancement;
  Future<double> setShadowEnhancement(
    double value, {
    required bool Function() allowed,
  });
}

enum ShadowTransfer { bt1886, gamma22, srgb, pq, hlg }

/// Match the pinned renderers' actual OUTPUT hook transfer. Never choose from a
/// filename, server HDR label, or an assumed Dolby output mode.
ShadowTransfer shadowOutputTransfer(String vo, String target, String source) {
  String gamma = target;
  if (gamma == 'auto') {
    if (vo == 'gpu-next') {
      gamma = 'bt.1886'; // pinned libplacebo pl_color_space_monitor
    } else if (vo == 'gpu') {
      gamma =
          const [
            'pq',
            'hlg',
            'linear',
            'smpte2084',
            'arib-std-b67',
          ].contains(source)
          ? 'gamma2.2'
          : source; // pinned gl_video automatic target rule
    } else {
      throw const AppFailure('当前画面输出暂不支持暗部增强');
    }
  }
  return switch (gamma.toLowerCase()) {
    'bt.1886' || 'gamma2.4' => ShadowTransfer.bt1886,
    'gamma2.2' || 'bt.709' => ShadowTransfer.gamma22,
    'srgb' => ShadowTransfer.srgb,
    'pq' || 'smpte2084' => ShadowTransfer.pq,
    'hlg' || 'arib-std-b67' => ShadowTransfer.hlg,
    _ => throw const AppFailure('当前输出色彩尚未确认，已保留原始画面'),
  };
}

/// A single OUTPUT pass after tone/color mapping. One gain on linear RGB keeps
/// channel ratios; exact early returns preserve black and the highlight region.
String shadowShader(
  ShadowTransfer transfer,
  double strength, {
  double picture = 0,
  bool p7Sdr = false,
}) {
  if ((!const [0.0, 0.25, 0.5, 0.75].contains(strength)) ||
      (strength == 0 && picture == 0) ||
      !picture.isFinite ||
      picture < 0 ||
      picture > 15) {
    throw const AppFailure('暗部增强强度无效');
  }
  final decode = switch (transfer) {
    ShadowTransfer.bt1886 => 'return pow(v, 2.4);',
    ShadowTransfer.gamma22 => 'return pow(v, 2.2);',
    ShadowTransfer.srgb =>
      'return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);',
    ShadowTransfer.pq =>
      '''float p = pow(v, 1.0 / (2523.0/32.0));
  return pow(max(p - 3424.0/4096.0, 0.0) / max(2413.0/128.0 - 2392.0/128.0*p, 0.000001), 1.0/(2610.0/16384.0));''',
    ShadowTransfer.hlg =>
      'return v <= 0.5 ? v*v/3.0 : (exp((v-0.55991073)/0.17883277)+0.28466892)/12.0;',
  };
  final encode = switch (transfer) {
    ShadowTransfer.bt1886 => 'return pow(v, 1.0/2.4);',
    ShadowTransfer.gamma22 => 'return pow(v, 1.0/2.2);',
    ShadowTransfer.srgb =>
      'return v <= 0.0031308 ? v*12.92 : 1.055*pow(v,1.0/2.4)-0.055;',
    ShadowTransfer.pq =>
      '''float p = pow(v, 2610.0/16384.0);
  return pow((3424.0/4096.0 + 2413.0/128.0*p)/(1.0+2392.0/128.0*p),2523.0/32.0);''',
    ShadowTransfer.hlg =>
      'return v <= 1.0/12.0 ? sqrt(3.0*v) : 0.17883277*log(12.0*v-0.28466892)+0.55991073;',
  };
  final cutoff = switch (transfer) {
    ShadowTransfer.pq => '0.0064',
    ShadowTransfer.hlg => '(1.0/12.0)',
    _ => '0.18',
  };
  final overall = picture == 0
      ? ''
      : p7Sdr
      ? '''float yy_picture_gain(float peak) {
  return (1.0 + ${(picture / 10).toStringAsFixed(6)}) / (1.0 + ${(picture / 10).toStringAsFixed(6)} * clamp(peak, 0.0, 1.0));
}
'''
      : '''float yy_picture_gain(float peak) {
  return 1.0 + ${(picture / 20).toStringAsFixed(6)} * (1.0 - clamp(peak, 0.0, 1.0));
}
''';
  final applyOverall = picture == 0
      ? ''
      : '''  linear_rgb *= yy_picture_gain(max(linear_rgb.r, max(linear_rgb.g, linear_rgb.b)));
''';
  final shadowGain = p7Sdr
      ? '''  linear_rgb *= (1.0 + ${(strength * 6.4).toStringAsFixed(2)}) / (1.0 + ${(strength * 6.4).toStringAsFixed(2)} * clamp(light / $cutoff, 0.0, 1.0));'''
      : '''  float weight = 1.0 - clamp(light / $cutoff, 0.0, 1.0);
  linear_rgb *= 1.0 + ${(strength * 3.2).toStringAsFixed(2)} * weight * weight;''';
  return '''//!HOOK OUTPUT
//!BIND HOOKED
//!DESC ${picture == 0 ? 'Yingyu optional shadow enhancement v2' : 'Yingyu colour-preserving enhancement v3'}
float yy_shadow_decode(float v) { $decode }
float yy_shadow_encode(float v) { $encode }
${overall}vec4 hook() {
  vec4 original = HOOKED_tex(HOOKED_pos);
  float peak = max(original.r, max(original.g, original.b));
  if (original.a < 0.999 || min(original.r, min(original.g, original.b)) < 0.0 ||
      peak <= 0.0 || peak >= ${picture == 0 ? 'yy_shadow_encode($cutoff)' : '1.0'}) return original;
  vec3 linear_rgb = vec3(yy_shadow_decode(original.r), yy_shadow_decode(original.g), yy_shadow_decode(original.b));
  float light = max(linear_rgb.r, max(linear_rgb.g, linear_rgb.b));
$shadowGain
$applyOverall  return vec4(yy_shadow_encode(linear_rgb.r), yy_shadow_encode(linear_rgb.g), yy_shadow_encode(linear_rgb.b), original.a);
}
''';
}

Future<String> storeShadowShader(String content) async {
  final cache = await getTemporaryDirectory();
  final folder = Directory('${cache.path}/yingyu-shadow-v1');
  await folder.create(recursive: true);
  final path = '${folder.path}/${sha256.convert(utf8.encode(content))}.hook';
  final file = File(path);
  if (!await file.exists() || await file.readAsString() != content) {
    await file.writeAsString(content, flush: true);
  }
  return path;
}

class ShadowEnhancement {
  ShadowEnhancement({this.shaderStore});
  final Future<String> Function(String)? shaderStore;
  double value = 0;
  double picture = 0;
  String? _original, _installed;
  Future<double> set(
    double next, {
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
    required bool Function() active,
    Future<String> Function(String)? store,
    double? pictureBrightness,
    bool dolbyInplace = false,
    bool p7Sdr = false,
    Future<void> Function()? prepareConfirmation,
    Future<void> Function(String)? confirm,
  }) async {
    void check() {
      if (!active()) throw const AppFailure('播放会话已改变');
    }

    check();
    final nextPicture = pictureBrightness ?? picture;
    if (!nextPicture.isFinite || nextPicture < 0 || nextPicture > 15) {
      throw const AppFailure('画面提亮须在 0 到 15 之间');
    }
    if (!const [0.0, 0.25, 0.5, 0.75].contains(next)) {
      throw const AppFailure('暗部增强强度无效');
    }
    if (value == next &&
        picture == nextPicture &&
        (next != 0 || nextPicture != 0 || _original == null)) {
      return value;
    }
    final before = await read('glsl-shaders');
    check();
    if (_installed != null && before != _installed) {
      throw const AppFailure('画面着色器已改变，请重新打开影片后调整');
    }
    if (_installed == null && _original == null && before.isNotEmpty) {
      throw const AppFailure('当前已有其他画面着色器，已保留原画面设置');
    }
    var desired = _original ?? before;
    if (next > 0 || nextPicture > 0) {
      final vo = await read('current-vo');
      check();
      if (vo != 'gpu' && vo != 'gpu-next') {
        throw const AppFailure('当前画面输出暂不支持暗部增强');
      }
      final target = await read('options/target-trc');
      check();
      final source = await read('video-out-params/gamma');
      check();
      final transfer = shadowOutputTransfer(vo, target, source);
      // Only selected P7 on a confirmed SDR target uses the stronger curve.
      // PQ/HLG targets, P5 and ordinary HDR keep the exact original bodies.
      final boost =
          dolbyInplace &&
          p7Sdr &&
          const {
            ShadowTransfer.bt1886,
            ShadowTransfer.gamma22,
            ShadowTransfer.srgb,
          }.contains(transfer);
      var content = shadowShader(
        transfer,
        next,
        picture: nextPicture,
        p7Sdr: boost,
      );
      if (dolbyInplace) {
        content = content.replaceFirst(
          RegExp(r'//!DESC [^\n]+'),
          '//!DESC Yingyu Dolby enhancement v1',
        );
      }
      final path = await (store ?? shaderStore ?? storeShadowShader)(
        content,
      ).timeout(const Duration(seconds: 2));
      check();
      if (path.isEmpty || path.contains(':') || path.contains('\n')) {
        throw const AppFailure('暗部增强准备失败，已保留原始画面');
      }
      desired = path;
    }
    _original ??= before;
    if (prepareConfirmation != null) await prepareConfirmation();
    check();
    try {
      await write('glsl-shaders', desired);
      check();
      if (await read('glsl-shaders') != desired) {
        throw const AppFailure('暗部增强设置未确认');
      }
      check();
      if (confirm != null) await confirm(desired);
      check();
    } catch (_) {
      if (!active()) rethrow;
      Object? proofFailure;
      try {
        if (prepareConfirmation != null) await prepareConfirmation();
      } catch (failure) {
        proofFailure = failure;
      }
      check();
      await write('glsl-shaders', before);
      check();
      if (await read('glsl-shaders') != before) {
        throw const AppFailure('暗部增强失败，原画面设置未能恢复');
      }
      check();
      if (proofFailure != null) {
        throw const AppFailure('画面增强失败，先前画面的恢复未通过渲染核对');
      }
      if (confirm != null) {
        try {
          await confirm(before);
        } catch (_) {
          if (!active()) rethrow;
          throw const AppFailure('画面增强失败，先前画面的恢复未通过渲染核对');
        }
      }
      check();
      rethrow;
    }
    value = next;
    picture = nextPicture;
    final off = next == 0 && nextPicture == 0;
    _installed = off ? null : desired;
    if (off) _original = null;
    return value;
  }
}
