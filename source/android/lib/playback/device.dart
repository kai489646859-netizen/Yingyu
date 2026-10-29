import 'package:flutter/services.dart';

class Device {
  /// Numeric window/system values only; neither is measured screen luminance.
  static String brightnessDescription(Map<String, dynamic> levels) {
    String number(String key) {
      final value = levels[key];
      return value is num && value.isFinite ? value.toString() : '未提供';
    }

    final automatic = levels['automaticBrightness'];
    return '窗口亮度=${number('windowBrightness')}（-1 跟随系统）；'
        '系统亮度原值=${number('systemBrightness')}；'
        '自动亮度=${automatic is bool ? automatic : '未提供'}；非实测屏幕亮度';
  }

  static const channel = MethodChannel('yingyu/device');
  static Future<bool> focus() async =>
      await channel.invokeMethod<bool>('focus') ?? false;
  static Future<void> release() => channel.invokeMethod('release');
  static Future<void> awake(bool value) => channel.invokeMethod('awake', value);
  static Future<Map<String, dynamic>> levels() async =>
      Map<String, dynamic>.from(await channel.invokeMethod('levels') as Map);
  static Future<void> brightness(double value) =>
      channel.invokeMethod('brightness', value);
  static Future<void> volume(double value) =>
      channel.invokeMethod('volume', value);
  static Future<int> memory() async {
    try {
      final info = Map<String, dynamic>.from(
        await channel.invokeMethod('memory') as Map,
      );
      final total = (info['total'] as num).toInt();
      final available = (info['available'] as num).toInt();
      return total >= 10 * 1024 * 1024 * 1024 &&
              available >= 2 * 1024 * 1024 * 1024
          ? 128
          : available < 1024 * 1024 * 1024
          ? 32
          : 64;
    } on MissingPluginException {
      return 64;
    }
  }
}
