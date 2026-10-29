import 'package:flutter/services.dart';
import '../core/models.dart';
import '../core/subtitle_document.dart';

class SubtitleImport {
  static const channel = MethodChannel('yingyu/subtitle-import');
  static Future<SubtitleDocument?> pick() async {
    final data = await channel.invokeMapMethod<String, dynamic>('pick');
    if (data == null) return null;
    final path = data['path'] as String?,
        name = data['name'] as String?,
        codec = data['codec'] as String?;
    if (path == null || name == null || codec == null) {
      throw const AppFailure('字幕文件未能完整读取');
    }
    return SubtitleDocument(path, name, codec, () async {
      await channel.invokeMethod<void>('release', path);
    });
  }
}
