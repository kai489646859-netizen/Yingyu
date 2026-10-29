import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'expansion_chevron.dart';
import '../core/account_display.dart';
import '../core/accounts.dart';
import '../core/models.dart';
import 'style.dart';
import 'expansion_action.dart';
import 'account_avatar_scope.dart';

const accountColors = [
  Color(0xFF3679C9),
  Color(0xFFC64878),
  Color(0xFF187F78),
  Color(0xFF8657BB),
  Color(0xFFA96D17),
  Color(0xFF637184),
];
const accountColorNames = ['海蓝', '玫红', '青绿', '紫色', '琥珀', '灰蓝'];

class AccountAvatar extends StatelessWidget {
  const AccountAvatar(this.account, {super.key, this.size = 36, this.display});
  final Session account;
  final AccountDisplay? display;
  final double size;
  @override
  Widget build(BuildContext context) {
    final base = display == null
        ? accentColor(context)
        : accountColors[display!.color];
    final color = Theme.of(context).brightness == Brightness.dark
        ? Color.lerp(base, Colors.white, .35)!
        : base;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .17),
        shape: BoxShape.circle,
      ),
      child: Text(
        (display?.name(account) ?? accountName(account)).characters.first,
        style: TextStyle(
          color: color,
          fontSize: size * .46,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final avatars = AccountAvatarScope.maybeOf(context)?.avatars;
    if (avatars == null) return fallback;
    return ListenableBuilder(
      listenable: avatars,
      builder: (context, _) {
        final bytes = avatars.bytes(account);
        if (bytes == null) return fallback;
        return ClipOval(
          child: Image.memory(
            bytes,
            key: ValueKey('emby-avatar-${accountKey(account)}'),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: 256,
            cacheHeight: 256,
            gaplessPlayback: false,
            errorBuilder: (_, _, _) => fallback,
          ),
        );
      },
    );
  }
}

class AccountSwitchButton extends StatelessWidget {
  const AccountSwitchButton({
    super.key,
    required this.account,
    required this.display,
    required this.onTap,
  });
  final Session account;
  final AccountDisplay display;
  final Future<void> Function()? onTap;
  @override
  Widget build(BuildContext context) => ExpansionAction(
    onOpen: onTap,
    builder: (expanded, activate) => Padding(
      padding: EdgeInsets.only(left: phoneValue(context, 2, 8)),
      child: Tooltip(
        message: '切换账号 · ${display.name(account)} · ${accountServer(account)}',
        child: Semantics(
          label:
              '切换账号，当前 ${display.name(account)}，${accountName(account)}，${account.base}',
          button: true,
          child: CupertinoButton(
            key: const Key('quick-account-switch'),
            padding: const EdgeInsets.all(4),
            onPressed: activate,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AccountAvatar(
                  account,
                  display: display,
                  size: phoneValue(context, 28, 36),
                ),
                const SizedBox(width: 4),
                ExpansionChevron(
                  expanded: expanded,
                  size: 12,
                  color: secondaryColor(context),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class AccountCard extends StatelessWidget {
  const AccountCard({
    super.key,
    required this.account,
    required this.display,
    this.onTap,
    this.profile = false,
  });
  final Session account;
  final bool profile;
  final AccountDisplay display;
  final Future<void> Function()? onTap;
  @override
  Widget build(BuildContext context) => ExpansionAction(
    onOpen: onTap,
    builder: (expanded, activate) => InkWell(
      key: const Key('account-avatar-switch'),
      onTap: activate,
      borderRadius: BorderRadius.circular(16),
      child: profile
          ? Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: phoneValue(context, 16, 24),
                vertical: phoneValue(context, 16, 24),
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    accentColor(context).withValues(alpha: .12),
                    accentColor(context).withValues(alpha: .02),
                  ],
                ),
              ),
              child: Row(
                children: [
                  AccountAvatar(
                    account,
                    display: display,
                    size: phoneValue(context, 44, 56),
                  ),
                  SizedBox(width: phoneValue(context, 12, 18)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '当前账号',
                          style: TextStyle(
                            fontSize: 11,
                            color: secondaryColor(context),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          display.name(account),
                          style: TextStyle(
                            fontSize: phoneValue(context, 18, 21),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (display.alias.isNotEmpty)
                          Text(
                            '账号：${accountName(account)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: secondaryColor(context),
                            ),
                          ),
                        Text(
                          account.base.toString(),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: secondaryColor(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onTap != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: ExpansionChevron(
                        expanded: expanded,
                        size: 18,
                        color: accentColor(context),
                      ),
                    ),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  AccountAvatar(account, display: display, size: 58),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '当前账号',
                          style: TextStyle(
                            fontSize: 12,
                            color: secondaryColor(context),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          display.name(account),
                          style: TextStyle(
                            fontSize: phoneValue(context, 18, 21),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (display.alias.isNotEmpty)
                          Text(
                            '账号：${accountName(account)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: secondaryColor(context),
                            ),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          account.base.toString(),
                          style: TextStyle(
                            fontSize: 13,
                            color: secondaryColor(context),
                          ),
                        ),
                        if (onTap != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            '点头像切换账号',
                            style: TextStyle(
                              fontSize: 12,
                              color: accentColor(context),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 10),
                    ExpansionChevron(
                      expanded: expanded,
                      size: 16,
                      color: secondaryColor(context),
                    ),
                  ],
                ],
              ),
            ),
    ),
  );
}
