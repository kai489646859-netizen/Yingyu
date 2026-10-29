import 'package:flutter/widgets.dart';
import '../core/account_avatars.dart';
import '../core/emby.dart';
import '../core/models.dart';

class AccountAvatarScope extends InheritedWidget {
  const AccountAvatarScope({
    super.key,
    required this.avatars,
    required this.transport,
    required super.child,
  });
  final AccountAvatars avatars;
  final EmbyClient transport;
  static AccountAvatarScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AccountAvatarScope>();

  Future<bool> refresh(Session account) async {
    final candidate = transport.forAccount(account);
    try {
      await candidate.validate();
      return await avatars.sync(candidate, force: true);
    } finally {
      candidate.retireBrowsing();
    }
  }

  @override
  bool updateShouldNotify(AccountAvatarScope oldWidget) =>
      avatars != oldWidget.avatars || transport != oldWidget.transport;
}
