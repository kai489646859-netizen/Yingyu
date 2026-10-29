import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'image_loading.dart';

enum LibraryDisplay {
  posters('海报墙', '海报下显示片名和年份，图上显示评分'),
  standard('图文列表', '海报旁显示影片简介');

  const LibraryDisplay(this.label, this.description);
  final String label, description;
}

enum PosterActionMode { menu, longPress }

extension PosterActionModeLabel on PosterActionMode {
  String get label => this == PosterActionMode.longPress ? '长按' : '三点';
}

class InterfacePreferences extends ChangeNotifier {
  InterfacePreferences(this.prefs);
  final SharedPreferences prefs;
  PosterActionMode get posterActionMode =>
      prefs.getString('yingyu.ui.posterActions.v1') == 'longPress'
      ? PosterActionMode.longPress
      : PosterActionMode.menu;
  Future<void> setPosterActionMode(PosterActionMode mode) async {
    if (!await prefs.setString('yingyu.ui.posterActions.v1', mode.name)) {
      throw const AppFailure('海报操作偏好保存失败');
    }
    notifyListeners();
  }

  LibraryDisplay get libraryDisplay =>
      LibraryDisplay.values
          .where(
            (value) =>
                value.name == prefs.getString('yingyu.ui.libraryDisplay.v1'),
          )
          .firstOrNull ??
      LibraryDisplay.posters;

  Future<void> setLibraryDisplay(LibraryDisplay value) async {
    if (!await prefs.setString('yingyu.ui.libraryDisplay.v1', value.name)) {
      throw const AppFailure('媒体库展示偏好保存失败');
    }
    notifyListeners();
  }

  // Zero disables only the rolling request quota, not pacing or concurrency.
  static const imageRequestLimits = [1, 2, 3, 0];
  int get imageRequestLimit {
    final value = prefs.getInt('yingyu.images.limit.v2');
    if (imageRequestLimits.contains(value)) return value!;
    return switch (prefs.getInt('yingyu.images.limit.v1')) {
      6 => 1,
      10 => 2,
      _ => 3,
    };
  }

  Future<void> setImageRequestLimit(int value) async {
    if (!imageRequestLimits.contains(value)) return;
    if (!await prefs.setInt('yingyu.images.limit.v2', value)) {
      throw const AppFailure('图片请求上限保存失败');
    }
    notifyListeners();
  }

  ImageLoadSpeed get imageLoadSpeed {
    final value = prefs.getString('yingyu.images.speed.v1');
    return ImageLoadSpeed.values.where((s) => s.name == value).firstOrNull ??
        ImageLoadSpeed.fast;
  }

  Future<void> setImageLoadSpeed(ImageLoadSpeed value) async {
    if (!await prefs.setString('yingyu.images.speed.v1', value.name)) {
      throw const AppFailure('图片加载速度保存失败');
    }
    notifyListeners();
  }

  int get actorCacheGB {
    final value = prefs.getInt('yingyu.people.gb.v1') ?? 1;
    return const [1, 3, 5].contains(value) ? value : 1;
  }

  Future<void> setActorCacheGB(int value) async {
    if (!const [1, 3, 5].contains(value)) return;
    if (!await prefs.setInt('yingyu.people.gb.v1', value)) {
      throw const AppFailure('演员缓存容量保存失败');
    }
    notifyListeners();
  }

  int get landscapeCacheGB {
    final value = prefs.getInt('yingyu.landscape.gb.v1') ?? 1;
    return const [1, 3, 5].contains(value) ? value : 1;
  }

  Future<void> setLandscapeCacheGB(int value) async {
    if (!const [1, 3, 5].contains(value)) return;
    if (!await prefs.setInt('yingyu.landscape.gb.v1', value)) {
      throw const AppFailure('横版海报缓存容量保存失败');
    }
    notifyListeners();
  }

  bool get prepareNext => prefs.getBool('yingyu.next.prepare.v1') ?? true;
  Future<void> setPrepareNext(bool value) async {
    if (!await prefs.setBool('yingyu.next.prepare.v1', value)) {
      throw const AppFailure('下一集准备设置保存失败');
    }
    notifyListeners();
  }

  int get cacheGB {
    final value = prefs.getInt('yingyu.images.gb.v1') ?? 5;
    return const [1, 5, 10].contains(value) ? value : 5;
  }

  static const imageAutoCleanChoices = {
    0: '从不自动清理',
    15: '15 天自动清理',
    30: '30 天自动清理',
    60: '60 天自动清理',
  };
  int get imageAutoCleanDays {
    final value = prefs.getInt('yingyu.images.autoCleanDays.v1');
    return imageAutoCleanChoices.containsKey(value) ? value! : 0;
  }

  Future<void> setImageAutoCleanDays(int value) async {
    if (!imageAutoCleanChoices.containsKey(value)) return;
    if (!await prefs.setInt('yingyu.images.autoCleanDays.v1', value)) {
      throw const AppFailure('自动清理偏好保存失败');
    }
    notifyListeners();
  }

  bool get reducedMotion =>
      prefs.getBool('yingyu.ui.reducedMotion.v1') ?? false;

  Future<void> setCacheGB(int value) async {
    if (!const [1, 5, 10].contains(value)) return;
    if (!await prefs.setInt('yingyu.images.gb.v1', value)) {
      throw const AppFailure('缓存容量保存失败');
    }
    notifyListeners();
  }

  Future<void> setReducedMotion(bool value) async {
    if (!await prefs.setBool('yingyu.ui.reducedMotion.v1', value)) {
      throw const AppFailure('动画偏好保存失败');
    }
    notifyListeners();
  }
}
