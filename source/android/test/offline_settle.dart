import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:flutter/services.dart';

void syntheticImagePaths() {
  final dir = Directory('build/synthetic-ui-metadata').absolute
    ..createSync(recursive: true);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => dir.path,
      );
}

/// Allow the real background catalogue isolate to finish outside FakeAsync.
Future<void> settleOffline(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (!tester.binding.hasScheduledFrame) break;
  }
  await tester.pumpAndSettle();
}
