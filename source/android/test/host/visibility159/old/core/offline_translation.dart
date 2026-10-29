import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'accounts.dart';
import 'models.dart';
import 'log.dart';

class TranslationStatus {
  const TranslationStatus({
    this.ready = false,
    this.phase = 'idle',
    this.error,
    this.elapsed = Duration.zero,
    this.network,
  });
  final bool ready;
  final String phase;
  final String? error;
  final Duration elapsed;
  final String? network;
  bool get busy => const {
    'downloading',
    'waiting_wifi',
    'waiting_network',
    'deleting',
  }.contains(phase);
  String get label => switch (phase) {
    'downloading' => '正在准备或下载语言包',
    'pending' => '上次下载尚未确认完成',
    'waiting_wifi' => '等待 Wi-Fi',
    'waiting_network' => '等待网络',
    'deleting' => '正在删除',
    'error' => ready ? '可离线使用 · 上次操作失败' : '操作失败',
    _ => ready ? '已下载 · 可离线使用' : '未下载',
  };
}

abstract class TranslationPlatform {
  Future<TranslationStatus> status();
  Future<TranslationStatus> download({required bool wifiOnly});
  Future<TranslationStatus> delete();
  Future<String> translate(String text);
}

class AndroidTranslationPlatform implements TranslationPlatform {
  static const channel = MethodChannel('yingyu/offline_translation');
  Future<TranslationStatus> _status(String method, [Object? arguments]) async {
    final value = await channel.invokeMapMethod<String, dynamic>(
      method,
      arguments,
    );
    if (value == null) throw const AppFailure('无法读取离线翻译状态');
    return TranslationStatus(
      ready: value['ready'] == true,
      phase: value['phase'] as String? ?? 'idle',
      error: value['error'] as String?,
      elapsed: Duration(
        milliseconds: value['elapsedMs'] is num
            ? (value['elapsedMs'] as num).toInt()
            : 0,
      ),
      network: value['network'] as String?,
    );
  }

  @override
  Future<TranslationStatus> status() => _status('status');
  @override
  Future<TranslationStatus> download({required bool wifiOnly}) =>
      _status('download', {'userInitiated': true, 'wifiOnly': wifiOnly});
  @override
  Future<TranslationStatus> delete() => _status('delete');
  @override
  Future<String> translate(String text) async {
    final value = await channel.invokeMethod<String>('translate', {
      'text': text,
    });
    if (value == null || value.trim().isEmpty) {
      throw const AppFailure('未取得译文，请重试');
    }
    return value;
  }
}

class TranslationRequest {
  bool cancelled = false;
  void cancel() => cancelled = true;
  void check() {
    if (cancelled) throw const TranslationCancelled();
  }
}

class TranslationCancelled implements Exception {
  const TranslationCancelled();
}

/// The model belongs to this installation; texts belong to one account/resource.
/// Construction, reads and translation never request a model download.
class OfflineTranslation extends ChangeNotifier {
  OfflineTranslation(this.prefs, {TranslationPlatform? platform, this.log})
    : platform = platform ?? AndroidTranslationPlatform();
  final SharedPreferences prefs;
  final TranslationPlatform platform;
  final DiagnosticLog? log;
  String? _lastStatusLog;
  static const cacheKey = 'yingyu.translation.cache.v1';
  static const autoKey = 'yingyu.translation.auto.v1';
  static const wifiKey = 'yingyu.translation.wifi.v1';
  static const cacheLimit = 1024 * 1024;
  static const entryLimit = 200;
  static const textLimit = 16000;
  static const estimate = '约 30 MB';
  static const modelEstimate = '官方通用估算约 30 MB，并非此中文包的实测大小。实际下载量及占用可能不同。';
  static const accuracyNotice = '机器翻译可能出现误译，仅供参考，请以原文为准。';
  static const downloadNotice = '语言包由 Google 模型服务提供。部分网络可能连接慢或无法访问；下载完成后可离线翻译。';
  TranslationStatus status = const TranslationStatus();
  String? warning;
  bool checking = false, _disposed = false, _modelAction = false;
  int _modelRevision = 0, _cacheRevision = 0;
  Future<void>? _refresh;
  Future<void> _writes = Future.value(), _translations = Future.value();
  bool get automatic => prefs.getBool(autoKey) ?? true;
  bool get wifiOnly => prefs.getBool(wifiKey) ?? true;
  bool get changingModel => _modelAction || status.busy;
  int get cacheBytes => utf8.encode(prefs.getString(cacheKey) ?? '').length;
  int get cacheRevision => _cacheRevision;
  int get modelRevision => _modelRevision;
  void _notify() {
    if (_disposed) return;
    final signature =
        '${status.phase}|${status.error}|${status.elapsed.inSeconds >= 120 && status.busy}';
    if (_lastStatusLog != signature) {
      _lastStatusLog = signature;
      if (status.phase != 'idle' || status.elapsed > Duration.zero) {
        log?.add(
          LogArea.app,
          '离线语言包：${status.label}；任务耗时=${status.elapsed.inSeconds} 秒；${status.network ?? "网络状态未提供"}；下载字节和精确大小接口未提供${status.error == null ? "" : "；${status.error}"}',
        );
      }
    }
    if (!_disposed) notifyListeners();
  }

  static String failure(Object e) {
    if (e is MissingPluginException) return '离线翻译组件暂不可用，请重新打开应用';
    if (e is PlatformException) {
      return switch (e.code) {
        'missing_model' => '请先下载离线语言包',
        'not_english' => '目前仅支持英语简介翻译为中文',
        'busy' => '语言包正在处理，请稍后重试',
        'invalid_text' => '简介过长或为空，无法翻译',
        _ => e.message ?? '离线翻译失败，请重试',
      };
    }
    if (e is AppFailure) return e.message;
    return '离线翻译操作失败，请重试';
  }

  Future<void> refresh() =>
      _refresh ??= _readStatus().whenComplete(() => _refresh = null);
  Future<void> _readStatus() async {
    final revision = _modelRevision;
    checking = !status.busy;
    _notify();
    try {
      final value = await platform.status();
      if (!_disposed && revision == _modelRevision) status = value;
    } catch (e) {
      if (revision == _modelRevision) {
        status = TranslationStatus(
          ready: status.ready,
          phase: 'error',
          error: failure(e),
        );
      }
    } finally {
      checking = false;
      _notify();
    }
  }

  Future<void> setAutomatic(bool value) async {
    if (!await prefs.setBool(autoKey, value)) {
      throw const AppFailure('翻译偏好保存失败');
    }
    _notify();
  }

  Future<void> setWifiOnly(bool value) async {
    if (!await prefs.setBool(wifiKey, value)) {
      throw const AppFailure('下载偏好保存失败');
    }
    _notify();
  }

  Future<void> download() {
    log?.add(LogArea.app, '用户确认下载离线语言包；仅 Wi-Fi=$wifiOnly；30 MB 为官方通用估算');
    return _changeModel(() => platform.download(wifiOnly: wifiOnly));
  }

  Future<void> deleteModel() => _changeModel(platform.delete);
  Future<void> _changeModel(Future<TranslationStatus> Function() action) async {
    if (changingModel || _disposed) return;
    _modelAction = true;
    ++_modelRevision;
    _notify();
    try {
      status = await action();
    } catch (e) {
      status = TranslationStatus(
        ready: status.ready,
        phase: 'error',
        error: failure(e),
      );
    } finally {
      _modelAction = false;
      _notify();
    }
  }

  // This is only an inexpensive UI prefilter. The bundled language identifier
  // checks English before inference; Latin script alone is never accepted as English.
  static bool candidate(String text) {
    if (text.trim().isEmpty || text.length > textLimit) return false;
    final latin = RegExp(r'[A-Za-z]').allMatches(text).length;
    final cjk = RegExp(
      r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]',
    ).allMatches(text).length;
    return latin >= 3 && cjk < latin / 3;
  }

  String _key(Session account, String id) => sha256
      .convert(
        utf8.encode(
          jsonEncode([accountKey(account), id, 'en', 'zh', 'mlkit-17.0.3-v1']),
        ),
      )
      .toString();
  String _source(String text) => sha256.convert(utf8.encode(text)).toString();
  Map<String, dynamic> _cache() {
    final raw = prefs.getString(cacheKey);
    if (raw == null) return {};
    try {
      if (utf8.encode(raw).length > cacheLimit) throw const FormatException();
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) throw const FormatException();
      return value;
    } catch (_) {
      throw const AppFailure('译文缓存无法读取，可在离线翻译设置中清除后重试');
    }
  }

  String? cached(Session account, String id, String text) {
    if (id.isEmpty) return null;
    final value = _cache()[_key(account, id)];
    return value is Map &&
            value['source'] == _source(text) &&
            value['text'] is String
        ? value['text'] as String
        : null;
  }

  Future<T> _write<T>(Future<T> Function() work) {
    final future = _writes.then((_) => work());
    _writes = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  Future<void> clearCache() {
    ++_cacheRevision;
    return _write(() async {
      if (!await prefs.remove(cacheKey)) throw const AppFailure('译文缓存清理失败');
      warning = null;
      _notify();
    });
  }

  Future<String> translate(
    Session account,
    String id,
    String text,
    TranslationRequest request,
  ) {
    final modelRevision = _modelRevision, cacheRevision = _cacheRevision;
    final future = _translations.then((_) async {
      void check() {
        request.check();
        if (_disposed || modelRevision != _modelRevision) {
          throw const TranslationCancelled();
        }
      }

      check();
      if (id.isEmpty || !candidate(text)) {
        throw const AppFailure('目前仅支持英语简介翻译为中文');
      }
      final hit = cached(account, id, text);
      if (hit != null) return hit;
      final current = await platform.status();
      check();
      status = current;
      _notify();
      if (!current.ready || current.busy) throw const AppFailure('请先下载离线语言包');
      final translated = await platform.translate(text);
      check();
      if (translated.trim().isEmpty || translated.length > textLimit * 2) {
        throw const AppFailure('译文内容无效，请重试');
      }
      await _write(() async {
        check();
        if (cacheRevision != _cacheRevision) return;
        final values = _cache();
        final key = _key(account, id);
        values.remove(key);
        values[key] = {'source': _source(text), 'text': translated};
        var encoded = jsonEncode(values);
        while (values.length > entryLimit ||
            utf8.encode(encoded).length > cacheLimit) {
          values.remove(values.keys.first);
          encoded = jsonEncode(values);
        }
        if (!await prefs.setString(cacheKey, encoded)) {
          throw const AppFailure('译文缓存保存失败，请重试');
        }
        _notify();
      });
      check();
      return translated;
    });
    _translations = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return future;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_modelRevision;
    super.dispose();
  }
}
