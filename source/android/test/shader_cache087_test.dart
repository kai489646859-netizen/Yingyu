import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/shader_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'slow optional directory falls back without a late renderer write',
    () async {
      final directory = Completer<String>();
      final writes = <String>[];
      final result = prepareShaderCache(
        read: (key) async => key == 'gpu-shader-cache' ? 'yes' : '',
        write: (key, value) async => writes.add('$key=$value'),
        directory: () => directory.future,
      );
      expect(
        await result.timeout(const Duration(seconds: 2)),
        ShaderCacheSetupResult.unavailable,
      );
      directory.complete('/private/late-shaders');
      await Future<void>.delayed(Duration.zero);
      expect(writes, isEmpty);
    },
  );

  test(
    'private shader directory is shared and preserves files on repeat setup',
    () async {
      final root = await Directory.systemTemp.createTemp('yingyu-shader-test-');
      addTearDown(() => root.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getTemporaryDirectory');
            return root.path;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final values = {'gpu-shader-cache': 'yes', 'gpu-shader-cache-dir': ''};
      Future<ShaderCacheSetupResult> prepare() => prepareShaderCache(
        read: (key) async => values[key]!,
        write: (key, value) async => values[key] = value,
      );
      expect(await prepare(), ShaderCacheSetupResult.ready);
      final cache = Directory(values['gpu-shader-cache-dir']!);
      expect(cache.parent.path, root.path);
      expect(await cache.exists(), true);
      final marker = File('${cache.path}/libplacebo.cache');
      await marker.writeAsString('synthetic program bytes');
      values['gpu-shader-cache-dir'] = '';
      expect(await prepare(), ShaderCacheSetupResult.ready);
      expect(values['gpu-shader-cache-dir'], cache.path);
      expect(await marker.readAsString(), 'synthetic program bytes');
      expect(values['gpu-shader-cache'], 'yes');
    },
  );

  for (final enabled in ['no', 'yes', 'unknown']) {
    test('explicit shader settings are retained: $enabled', () async {
      final writes = <String>[];
      final result = await prepareShaderCache(
        read: (key) async =>
            key == 'gpu-shader-cache' ? enabled : '/custom/cache',
        write: (key, value) async => writes.add('$key=$value'),
        directory: () async => throw StateError('must not create a directory'),
      );
      expect(result, switch (enabled) {
        'no' => ShaderCacheSetupResult.disabled,
        'yes' => ShaderCacheSetupResult.preserved,
        _ => ShaderCacheSetupResult.unavailable,
      });
      expect(writes, isEmpty);
    });
  }

  test('unavailable private directory does not alter MPV properties', () async {
    final writes = <String>[];
    expect(
      await prepareShaderCache(
        read: (key) async => key == 'gpu-shader-cache' ? 'yes' : '',
        write: (key, value) async => writes.add('$key=$value'),
        directory: () async =>
            throw const FileSystemException('synthetic failure'),
      ),
      ShaderCacheSetupResult.unavailable,
    );
    expect(writes, isEmpty);
  });

  test(
    'rejected cache directory is restored without failing playback',
    () async {
      final writes = <String>[];
      expect(
        await prepareShaderCache(
          read: (key) async => key == 'gpu-shader-cache' ? 'yes' : '',
          write: (key, value) async => writes.add('$key=$value'),
          directory: () async => '/private/shaders',
        ),
        ShaderCacheSetupResult.unavailable,
      );
      expect(writes, [
        'gpu-shader-cache-dir=/private/shaders',
        'gpu-shader-cache-dir=',
      ]);
    },
  );

  test(
    'failed property write is optional and attempts to restore the old path',
    () async {
      final writes = <String>[];
      expect(
        await prepareShaderCache(
          read: (key) async => key == 'gpu-shader-cache' ? 'yes' : '',
          write: (key, value) async {
            writes.add('$key=$value');
            if (value.isNotEmpty) {
              throw StateError('synthetic property failure');
            }
          },
          directory: () async => '/private/shaders',
        ),
        ShaderCacheSetupResult.unavailable,
      );
      expect(writes, [
        'gpu-shader-cache-dir=/private/shaders',
        'gpu-shader-cache-dir=',
      ]);
    },
  );

  test('late directory completion cannot mutate an inactive player', () async {
    var active = true;
    final writes = <String>[];
    expect(
      await prepareShaderCache(
        read: (key) async => key == 'gpu-shader-cache' ? 'yes' : '',
        write: (key, value) async => writes.add('$key=$value'),
        directory: () async {
          active = false;
          return '/private/shaders';
        },
        active: () => active,
      ),
      ShaderCacheSetupResult.unavailable,
    );
    expect(writes, isEmpty);
  });
}
