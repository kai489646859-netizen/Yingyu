import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Inject slow and failed platform writes without touching device preferences.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show syntheticSession;

class ControlledProgressPreferences extends InMemorySharedPreferencesStore {
  ControlledProgressPreferences() : super.withData({});
  final entered = Completer<void>(), release = Completer<void>();
  bool delayRemoval = false, failRemoval = false, failObservation = false;
  @override
  Future<bool> remove(String key) async {
    if (key.startsWith('flutter.yingyu.position.') &&
        !key.endsWith('.baseline')) {
      if (failRemoval) return false;
      final result = await super.remove(key);
      if (delayRemoval) {
        entered.complete();
        await release.future;
      }
      return result;
    }
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String type, String key, Object value) =>
      failObservation && key.endsWith('.baseline')
      ? Future.value(false)
      : super.setValue(type, key, value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledProgressPreferences platform;
  late AppStore store;
  final account = syntheticSession();
  MediaItem observed(int seconds) => MediaItem({
    'Id': 'episode',
    'Type': 'Episode',
    'UserData': {
      'PlaybackPositionTicks': ticks(Duration(seconds: seconds)),
      'Played': false,
    },
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    platform = ControlledProgressPreferences();
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = platform;
    addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
    store = AppStore(await SharedPreferences.getInstance());
  });
  test(
    'delayed old confirmation preserves a newer checkpoint and its server baseline',
    () async {
      await store.saveProgress(
        account,
        'episode',
        const Duration(seconds: 30),
        serverBaseline: observed(10),
      );
      platform.delayRemoval = true;
      final old = store.confirmProgress(
        account,
        'episode',
        const Duration(seconds: 30),
      );
      await platform.entered.future;
      await store.saveProgress(
        account,
        'episode',
        const Duration(seconds: 90),
        serverBaseline: observed(50),
      );
      platform.release.complete();
      await old;
      expect(
        store.localProgress(account, 'episode'),
        const Duration(seconds: 90),
      );
      expect(
        store.resume(account, observed(50)).position,
        const Duration(seconds: 90),
        reason:
            'old cleanup must not discard the baseline of the new local checkpoint',
      );
      await store.prefs.reload();
      expect(
        store.resume(account, observed(50)).position,
        const Duration(seconds: 90),
      );
    },
  );
  test(
    'failed checkpoint cleanup is reported instead of claiming local confirmation',
    () async {
      await store.saveProgress(
        account,
        'episode',
        const Duration(seconds: 30),
        serverBaseline: observed(10),
      );
      platform.failRemoval = true;
      await expectLater(
        store.confirmProgress(account, 'episode', const Duration(seconds: 30)),
        throwsA(isA<AppFailure>()),
      );
      await store.prefs.reload();
      expect(
        store.localProgress(account, 'episode'),
        const Duration(seconds: 30),
      );
    },
  );
  test(
    'failed server-baseline persistence is reported to the playback caller',
    () async {
      await store.saveProgress(
        account,
        'episode',
        const Duration(seconds: 30),
        serverBaseline: observed(10),
      );
      platform.failObservation = true;
      await expectLater(
        store.observeProgress(
          account,
          observed(20),
          const Duration(seconds: 30),
        ),
        throwsA(isA<AppFailure>()),
      );
      await store.prefs.reload();
      expect(
        store.resume(account, observed(10)).position,
        const Duration(seconds: 30),
      );
    },
  );
}
