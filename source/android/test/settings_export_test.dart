import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/log_export.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/settings_export.dart';
import 'package:yingyu/core/settings_import.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/danmaku_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppStore store;
  late InterfacePreferences appearance;
  late BrowsePreferences browse;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'yingyu.theme.v1': 'dark',
      'yingyu.playback.holdSpeed.v1': 2,
      'yingyu.images.limit.v1': 6,
      'yingyu.accounts.v1': 'private-account-token',
      'yingyu.tracks.v1': 'private-track-memory',
      'yingyu.logs.v1': ['private-log'],
      'danmaku.settings.v1':
          '{"featured":true,"area":0.3,'
          '"compatible":"https://private.example/?key=secret"}',
    });
    final prefs = await SharedPreferences.getInstance();
    store = AppStore(prefs);
    appearance = InterfacePreferences(prefs);
    browse = BrowsePreferences(prefs);
  });

  tearDown(() {
    browse.dispose();
    appearance.dispose();
    store.dispose();
  });

  test('exports effective settings and excludes private records', () {
    final snapshot = SettingsExport.snapshot(store, appearance, browse);
    final result = jsonDecode(snapshot) as Map<String, dynamic>;
    expect(result['format'], 'yingyu.settings');
    expect(result['schemaVersion'], 1);
    expect(result['appearance']['theme'], 'dark');
    expect(result['playback']['holdSpeed'], 2);
    expect(result['cacheAndLoading']['imageRequestLimit'], 1);
    expect(result['danmaku']['featured'], true);
    expect(result['danmaku']['area'], .3);
    expect(snapshot, isNot(contains('private')));
    expect(snapshot, isNot(contains('secret')));
  });

  test(
    'reimports a schema 1 export and preserves private preferences',
    () async {
      final oldExport = SettingsExport.snapshot(store, appearance, browse);
      final before = jsonDecode(oldExport) as Map<String, dynamic>;
      before['appVersion'] = '2.2.5';
      before['accounts'] = 'attempted replacement';
      before['danmaku']['compatible'] = 'attempted replacement';
      await store.prefs.setString('yingyu.theme.v1', 'light');
      await store.setHoldSpeed(3);
      final look = DanmakuPreferences.read(store.prefs);
      await look
          .copyWith(appearance: look.appearance.update(area: .6))
          .save(store.prefs);
      final plan = SettingsImport.parse(
        Uint8List.fromList(utf8.encode(jsonEncode(before))),
        store,
        appearance,
        browse,
      );
      expect(store.theme.name, 'light');
      await plan.apply();
      expect(SettingsExport.snapshot(store, appearance, browse), oldExport);
      expect(
        store.prefs.getString('yingyu.accounts.v1'),
        'private-account-token',
      );
      expect(store.prefs.getString('yingyu.tracks.v1'), 'private-track-memory');
      expect(
        DanmakuPreferences.read(store.prefs).compatible,
        'https://private.example/?key=secret',
      );
    },
  );

  test('validates all supplied settings before applying any of them', () {
    final invalid = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'yingyu.settings',
          'schemaVersion': 1,
          'appearance': {'theme': 'light'},
          'danmaku': {'opacity': 200},
        }),
      ),
    );
    expect(
      () => SettingsImport.parse(invalid, store, appearance, browse),
      throwsA(isA<AppFailure>()),
    );
    expect(store.theme.name, 'dark');
  });

  for (final outcome in ['saved', 'cancelled', 'failed']) {
    test('settings export $outcome cleans up the staged JSON', () async {
      final folder = await Directory.systemTemp.createTemp('settings-export');
      addTearDown(() => folder.delete(recursive: true));
      final staged = File('${folder.path}/settings.json');
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(
        () => messenger.setMockMethodCallHandler(LogFileExport.channel, null),
      );
      messenger.setMockMethodCallHandler(LogFileExport.channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'prepare':
            return staged.path;
          case 'saveSettings':
            expect(call.arguments, matches(r'^Yingyu-settings-.*\.json$'));
            expect(jsonDecode(staged.readAsStringSync())['schemaVersion'], 1);
            if (outcome == 'failed') throw PlatformException(code: 'write');
            return outcome == 'saved';
          case 'discard':
            await staged.delete();
            return null;
          default:
            throw MissingPluginException(call.method);
        }
      });
      final export = SettingsExport.save(store, appearance, browse);
      if (outcome == 'failed') {
        await expectLater(export, throwsA(isA<PlatformException>()));
      } else {
        expect(await export, outcome == 'saved');
      }
      expect(calls, ['prepare', 'saveSettings', 'discard']);
      expect(staged.existsSync(), false);
    });
  }
}
