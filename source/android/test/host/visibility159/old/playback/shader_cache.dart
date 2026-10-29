import 'dart:io';
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

enum ShaderCacheSetupResult { ready, preserved, disabled, unavailable }

/// The pinned MPV Android build otherwise relies on HOME/XDG_CACHE_HOME.
/// Give both gpu and gpu-next a private, reclaimable shader cache before VO
/// initialization. The native renderer validates cached programs and falls back
/// to compiling the same shader when a binary cannot be used.
Future<ShaderCacheSetupResult> prepareShaderCache({
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) write,
  Future<String> Function()? directory,
  bool Function()? active,
}) async {
  bool current() => active?.call() ?? true;
  var changed = false;
  var previous = '';
  try {
    if (!current()) return ShaderCacheSetupResult.unavailable;
    final enabled = await read('gpu-shader-cache');
    if (!current()) return ShaderCacheSetupResult.unavailable;
    if (enabled == 'no') return ShaderCacheSetupResult.disabled;
    if (enabled != 'yes') return ShaderCacheSetupResult.unavailable;
    previous = await read('gpu-shader-cache-dir');
    if (!current()) return ShaderCacheSetupResult.unavailable;
    if (previous.isNotEmpty) return ShaderCacheSetupResult.preserved;
    final path = await (directory ?? _shaderCacheDirectory)().timeout(
      const Duration(milliseconds: 600),
    );
    if (!current() || path.isEmpty) return ShaderCacheSetupResult.unavailable;
    changed = true;
    await write('gpu-shader-cache-dir', path);
    if (!current()) return ShaderCacheSetupResult.unavailable;
    if (await read('gpu-shader-cache-dir') == path) {
      return current()
          ? ShaderCacheSetupResult.ready
          : ShaderCacheSetupResult.unavailable;
    }
  } catch (_) {
    // Shader reuse is optional: directory/plugin/driver failures must not stop
    // playback or change the renderer, quality, colour or decoding settings.
  }
  if (changed && current()) {
    try {
      await write('gpu-shader-cache-dir', previous);
    } catch (_) {
      // An unavailable cache does not prevent normal shader compilation.
    }
  }
  return ShaderCacheSetupResult.unavailable;
}

Future<String> _shaderCacheDirectory() async {
  final parent = await getTemporaryDirectory();
  final directory = Directory('${parent.path}/mpv-shaders-v1');
  await directory.create(recursive: true);
  return directory.path;
}
