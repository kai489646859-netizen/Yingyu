import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() main) async {
  setUp(() {
    // Pure Dart/local HTTP tests must retain their real loopback transport.
    // Widget tests create their binding while registering with testWidgets.
    if (BindingBase.debugBindingType() == null) return;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('yingyu/offline_translation'),
          (call) async => call.method == 'status'
              ? {'ready': false, 'phase': 'idle'}
              : throw PlatformException(
                  code: 'unexpected_translation_operation',
                ),
        );
  });
  await main();
}
