import 'dart:async';
import 'dart:io';
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';
import 'core/image_references.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'core/emby.dart';
import 'core/store.dart';
import 'core/log.dart';
import 'playback/device.dart';
import 'version.dart';
import 'core/process_exit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      '映屿与 libmpv 原生依赖',
    ], await rootBundle.loadString('assets/OPEN_SOURCE_NOTICES.txt'));
  });
  MediaKit.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final log = await DiagnosticLog.open(prefs, console: false);
  ImageReferences images;
  try {
    images = ImageReferences(
      file: File(
        '${(await getApplicationSupportDirectory()).path}/image-references-v1.jsonl',
      ),
    );
    await images.load();
  } catch (_) {
    images = ImageReferences()
      ..healthy = false
      ..warning = '图片引用目录暂不可用，已保留图片缓存';
  }
  final store = AppStore(prefs, log: log, images: images);
  unawaited(recordPreviousExit(log));
  log.add(
    LogArea.app,
    '软件启动；构建=$diagnosticBuild；日志上限=${DiagnosticLog.limit} 条',
  );
  final bufferMiB = await Device.memory();
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      bufferMiB.clamp(32, 96) * 1024 * 1024;
  runApp(
    YingyuApp(
      store: store,
      api: EmbyClient(log: log),
      bufferMiB: bufferMiB,
    ),
  );
}
