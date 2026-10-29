import 'dart:async';
import 'package:flutter/foundation.dart';
import 'accounts.dart';
import 'emby.dart';
import 'models.dart';
import 'store.dart';

/// A successful switch publishes a whole client, never just a different token.
/// Old views, late replies and progress saves retain their original client.
class AccountController extends ChangeNotifier {
  AccountController(this.store, this.transport);
  final AppStore store;
  final EmbyClient transport;
  EmbyClient? api;
  bool connected = false, busy = false, disposed = false;
  bool _transportUsed = false;
  bool _switchingAfterLogout = false;
  bool get switchingAfterLogout => _switchingAfterLogout;
  String? error;
  VoidCallback? onExpired;
  List<SavedAccount> get accounts => store.accounts.accounts;
  SavedAccount? get selected => store.accounts.selected;

  void changed() {
    if (!disposed) notifyListeners();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) throw const AppFailure('正在处理账号，请稍候');
    busy = true;
    changed();
    try {
      await action();
    } finally {
      busy = false;
      _switchingAfterLogout = false;
      changed();
    }
  }

  void _publish(EmbyClient next) {
    api?.retireBrowsing();
    api = next;
    connected = true;
    error = null;
    next.onUnauthorized = () => unawaited(_expired(next));
    unawaited(store.avatars.sync(next));
    changed();
  }

  Future<void> _expired(EmbyClient owner) async {
    if (disposed || api != owner || !connected) return;
    connected = false;
    error = '登录已过期，请重新登录或切换账号';
    owner.retireBrowsing();
    onExpired?.call();
    changed();
    try {
      await store.accounts.expire(accountKey(owner.session!));
    } catch (e) {
      // Never replace a newer account's state with an older persistence error.
      if (api == owner) error = '登录已过期；${safeError(e)}';
    }
    changed();
  }

  Future<void> restore() => _run(() async {
    error = null;
    try {
      final session = await store.loadSession();
      if (session == null) return;
      if (selected!.needsLogin) {
        error = '登录已过期，请重新登录或切换账号';
        return;
      }
      final candidate = _transportUsed
          ? transport.forAccount(session)
          : transport;
      _transportUsed = true;
      candidate.session = session;
      await candidate.validate();
      if (!disposed) _publish(candidate);
    } catch (e) {
      error = safeError(e);
      if (e is AppFailure && e.status == 401 && selected != null) {
        try {
          await store.accounts.expire(selected!.id);
        } catch (storageError) {
          error = '登录已过期；${safeError(storageError)}';
        }
      }
    }
  });

  Future<void> switchTo(SavedAccount target) => _run(() => _switchTo(target));

  Future<void> reorder(List<String> ids) =>
      _run(() => store.accounts.reorder(List.of(ids)));

  Future<void> _switchTo(SavedAccount target) async {
    final saved = accounts.where((a) => a.id == target.id).firstOrNull;
    if (saved == null) throw const AppFailure('这个账号已从本机移除');
    if (connected && accountKey(api!.session!) == saved.id) return;
    if (saved.needsLogin) throw const AppFailure('这个账号需要重新登录');
    final candidate = transport.forAccount(saved.session);
    try {
      await candidate.validate();
    } catch (e) {
      if (e is AppFailure && e.status == 401) {
        await store.accounts.expire(saved.id);
      }
      rethrow;
    }
    if (disposed) return;
    await store.saveSession(saved.session);
    if (!disposed) _publish(candidate);
  }

  Future<void> login(
    String server,
    String username,
    String password, {
    SavedAccount? replacing,
    String alias = '',
  }) => _run(() async {
    await store.accounts.load(store.deviceId);
    final base = normalizeServer(server);
    final existing =
        replacing ??
        accounts
            .where(
              (a) =>
                  a.session.base == base &&
                  a.session.username == username.trim(),
            )
            .firstOrNull;
    // Separate device sessions avoid logging out another saved Emby user.
    final device =
        existing?.session.deviceId ??
        (accounts.isEmpty
            ? await store.deviceId()
            : 'Yingyu-Android-${newId()}');
    final candidate = transport.forAccount();
    final result = await candidate.login(server, username, password, device);
    if (replacing != null && accountKey(result) != replacing.id) {
      throw const AppFailure('服务器返回了不同账号，未替换原账号；请使用添加账号');
    }
    if (disposed) return;
    if (alias.trim().isNotEmpty) {
      await store.saveAccountDisplay(
        result,
        alias.trim(),
        store.accountDisplays.read(result).color,
      );
    }
    await store.saveSession(result);
    if (!disposed) _publish(candidate);
  });

  Future<void> remove(
    SavedAccount target, {
    bool switchToRemaining = false,
  }) => _run(() async {
    final wasCurrent = selected?.id == target.id;
    await store.accounts.remove(target.id);
    _switchingAfterLogout =
        switchToRemaining && wasCurrent && accounts.any((a) => !a.needsLogin);
    if (api != null && accountKey(api!.session!) == target.id) {
      api!.retireBrowsing();
      api = null;
      connected = false;
      error = null;
    }
    changed();
    // Removing a device login is explicit. Switching never invokes logout.
    try {
      await transport.forAccount(target.session).logout();
    } catch (e) {
      error = '已从本机移除，服务器注销未完成：${safeError(e)}';
    }
    if (!switchToRemaining || !wasCurrent || disposed || accounts.isEmpty) {
      return;
    }
    final logoutWarning = error;
    String? switchFailure;
    for (final next in accounts.where((a) => !a.needsLogin).toList()) {
      try {
        await _switchTo(next);
        // Publishing the new account clears old errors; retain a real logout
        // failure even when the remaining account can be used successfully.
        error = logoutWarning;
        return;
      } catch (e) {
        switchFailure = '已退出当前账号，自动切换未完成：${safeError(e)}';
        if (disposed) return;
        // Only an expired credential permits trying the next saved account.
        // Connection, identity and storage failures remain visible, without
        // cycling through every server or deleting another account.
        if (e is! AppFailure || e.status != 401) break;
      }
    }
    error = [?logoutWarning, switchFailure ?? '已退出当前账号，其余账号需要重新登录。'].join('\n');
  });

  @override
  void dispose() {
    disposed = true;
    api?.retireBrowsing();
    super.dispose();
  }
}
