import '../core/models.dart';

abstract class PictureBrightnessBackend {
  Future<double> readPictureBrightness({required bool Function() allowed});
  Future<double> setPictureBrightness(
    double value, {
    required bool Function() allowed,
  });
}

/// Pinned MPV's file-local option restores on end-file. Never changes HDR
/// metadata, decoder, output target or tone-mapping policy. Default is untouched.
Future<double> readPictureGamma({
  required Future<String> Function(String) read,
  required bool Function() active,
}) async {
  if (!active()) throw const AppFailure('播放会话已改变');
  final value = double.tryParse(await read('gamma'));
  if (!active()) throw const AppFailure('播放会话已改变');
  if (value == null || !value.isFinite || value < -100 || value > 100) {
    throw const AppFailure('当前画面不支持明暗调整');
  }
  return value;
}

Future<double> writePictureGamma({
  required double value,
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) write,
  required bool Function() active,
}) async {
  if (!value.isFinite || value < 0 || value > 15) {
    throw const AppFailure('画面提亮须在 0 到 15 之间');
  }
  final before = await readPictureGamma(read: read, active: active);
  try {
    if (!active()) throw const AppFailure('播放会话已改变');
    await write('file-local-options/gamma', value.toStringAsFixed(3));
    final actual = await readPictureGamma(read: read, active: active);
    if ((actual - value).abs() > .001) throw const AppFailure('画面调整未被确认');
    return actual;
  } catch (_) {
    if (active()) {
      await write('file-local-options/gamma', before.toStringAsFixed(3));
      final restored = await readPictureGamma(read: read, active: active);
      if ((restored - before).abs() > .001) {
        throw const AppFailure('画面调整未能恢复，请退出后重试');
      }
    }
    rethrow;
  }
}
