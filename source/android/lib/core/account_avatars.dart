import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'accounts.dart';
import 'background_work.dart';
import 'emby.dart';
import 'models.dart';

/// Small account-scoped thumbnails. No media requests, periodic polling or
/// stored credentials. UserDto metadata is reused from the existing login check.
class AccountAvatars extends ChangeNotifier {
  AccountAvatars(this.prefs);
  final SharedPreferences prefs;
  static const maxBytes = 256 * 1024;
  final _images = <String, ({String tag, Uint8List bytes})?>{};
  final _epochs = <String, int>{};
  final _errors = <String, String>{};
  Future<void> _writes = Future.value();
  bool _disposed = false;
  String _key(Session account) =>
      'yingyu.avatar.v1.${sha256.convert(utf8.encode(accountKey(account)))}';

  Uint8List? bytes(Session account) {
    final key = _key(account);
    if (!_images.containsKey(key)) {
      _images[key] = null;
      try {
        final raw = prefs.getString(key);
        if (raw != null && raw.length <= maxBytes * 2) {
          final data = jsonDecode(raw) as Map;
          final value = base64Decode(data['image'] as String);
          if (value.isNotEmpty && value.length <= maxBytes) {
            _images[key] = (tag: data['tag'] as String, bytes: value);
          }
        }
      } catch (_) {
        /* A corrupt thumbnail falls back to the account initial. */
      }
    }
    return _images[key]?.bytes;
  }

  String? error(Session account) => _errors[_key(account)];

  Future<bool> sync(EmbyClient owner, {bool force = false}) async {
    final account = owner.session;
    final tag = owner.primaryImageTag;
    if (_disposed || account == null || tag == null) return false;
    final key = _key(account);
    bytes(account);
    if (!force && _images[key]?.tag == tag) return true;
    final epoch = (_epochs[key] ?? 0) + 1;
    _epochs[key] = epoch;
    bool current() =>
        !_disposed &&
        _epochs[key] == epoch &&
        identical(owner.session, account) &&
        !owner.backgroundWork.paused;
    final abort = Completer<void>();
    Timer? timer;
    try {
      owner.backgroundWork.attach(abort);
      timer = Timer(const Duration(seconds: 8), () {
        if (!abort.isCompleted) abort.complete();
      });
      Uint8List? image;
      if (tag.isNotEmpty) {
        final request =
            http.AbortableRequest(
                'GET',
                owner.endpoint(
                  account.base,
                  'Users/${Uri.encodeComponent(account.userId)}/Images/Primary',
                  {'Tag': tag, 'MaxWidth': '256', 'MaxHeight': '256'},
                ),
                abortTrigger: abort.future,
              )
              ..followRedirects = false
              ..headers.addAll(
                owner.headers(
                  account.deviceId,
                  token: account.token,
                  userId: account.userId,
                ),
              );
        final response = await owner.client
            .send(request)
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200 ||
            !(response.headers['content-type'] ?? '').toLowerCase().startsWith(
              'image/',
            ) ||
            (response.contentLength ?? 0) > maxBytes) {
          throw const AppFailure('Emby 头像暂时无法读取');
        }
        final body = BytesBuilder(copy: false);
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 8),
        )) {
          if (!current() || abort.isCompleted) throw const BackgroundPaused();
          if (body.length + chunk.length > maxBytes) {
            throw const AppFailure('Emby 头像图片过大');
          }
          body.add(chunk);
        }
        image = body.takeBytes();
        final codec = await ui.instantiateImageCodec(
          image,
          targetWidth: 256,
          targetHeight: 256,
          allowUpscaling: false,
        );
        try {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      }
      if (!current()) return false;
      var saved = false;
      _writes = _writes.then((_) async {
        if (!current()) return;
        final ok = image == null
            ? await prefs.remove(key)
            : await prefs.setString(
                key,
                jsonEncode({'tag': tag, 'image': base64Encode(image)}),
              );
        if (!ok) throw const AppFailure('头像保存失败，请重试');
        if (!current()) return;
        _images[key] = image == null ? null : (tag: tag, bytes: image);
        _errors.remove(key);
        saved = true;
        notifyListeners();
      });
      final pending = _writes;
      _writes = pending.catchError((Object _) {});
      await pending;
      return saved;
    } catch (_) {
      if (current()) {
        _errors[key] = '头像同步失败，已保留原头像，请重试';
        notifyListeners();
      }
      return false;
    } finally {
      timer?.cancel();
      if (!abort.isCompleted) abort.complete();
      owner.backgroundWork.detach(abort);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
