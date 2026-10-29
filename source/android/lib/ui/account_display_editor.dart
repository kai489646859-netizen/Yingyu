import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/account_display.dart';
import 'account_avatar.dart';
import 'account_avatar_scope.dart';
import 'style.dart';

class AccountDisplayEditor extends StatefulWidget {
  const AccountDisplayEditor({
    super.key,
    required this.store,
    required this.account,
  });
  final AppStore store;
  final Session account;
  @override
  State<AccountDisplayEditor> createState() => _AccountDisplayEditorState();
}

class _AccountDisplayEditorState extends State<AccountDisplayEditor> {
  late final original = widget.store.accountDisplays.read(widget.account);
  late final alias = TextEditingController(text: original.alias);
  late int color = original.color;
  bool busy = false;
  bool syncingAvatar = false;
  String? avatarNotice;
  String? error;
  @override
  void dispose() {
    alias.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.store.saveAccountDisplay(widget.account, alias.text, color);
      if (mounted) {
        setState(() => busy = false);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = safeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('账号备注与头像'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: busy ? null : () => Navigator.pop(context),
          icon: const Icon(CupertinoIcons.back),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: EdgeInsets.all(phoneValue(context, 16, 24)),
              children: [
                Center(
                  child: AccountAvatar(
                    widget.account,
                    size: phoneValue(context, 56, 76),
                    display: AccountDisplay(
                      alias: alias.text.trim(),
                      color: color,
                    ),
                  ),
                ),
                SizedBox(height: phoneValue(context, 16, 24)),
                if (AccountAvatarScope.maybeOf(context) != null) ...[
                  Center(
                    child: TextButton(
                      key: const Key('sync-emby-avatar'),
                      onPressed: busy || syncingAvatar
                          ? null
                          : () async {
                              final scope = AccountAvatarScope.maybeOf(
                                context,
                              )!;
                              setState(() {
                                syncingAvatar = true;
                                avatarNotice = null;
                              });
                              String notice;
                              try {
                                final ok = await scope.refresh(widget.account);
                                notice = ok
                                    ? (scope.avatars.bytes(widget.account) ==
                                              null
                                          ? 'Emby 未设置头像，使用本机头像'
                                          : '已同步 Emby 头像')
                                    : '头像同步失败，已保留原头像，请重试';
                              } catch (e) {
                                notice = safeError(e);
                              }
                              if (mounted) {
                                setState(() {
                                  syncingAvatar = false;
                                  avatarNotice = notice;
                                });
                              }
                            },
                      child: Text(syncingAvatar ? '正在同步…' : '同步 Emby 头像'),
                    ),
                  ),
                  if (avatarNotice != null)
                    Text(avatarNotice!, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                ],
                TextField(
                  key: const Key('account-alias'),
                  controller: alias,
                  maxLength: 20,
                  enabled: !busy,
                  onChanged: (_) => setState(() {}),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => save(),
                  decoration: const InputDecoration(
                    labelText: '备注名称',
                    hintText: '例如：家用影院、原盘账号',
                  ),
                ),
                const SizedBox(height: 12),
                const Text('备用头像颜色'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (var i = 0; i < accountColors.length; i++)
                      Semantics(
                        selected: color == i,
                        button: true,
                        label: accountColorNames[i],
                        child: InkWell(
                          key: ValueKey('account-color-$i'),
                          customBorder: const CircleBorder(),
                          onTap: busy ? null : () => setState(() => color = i),
                          child: Container(
                            width: 44,
                            height: 44,
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: color == i
                                  ? Border.all(
                                      color: accentColor(context),
                                      width: 3,
                                    )
                                  : null,
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: accountColors[i],
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  '优先显示 Emby 头像，未设置时使用本机头像。备注和备用颜色仅在这台设备生效，登录用户名仍为 ${widget.account.username}。',
                  style: TextStyle(
                    fontSize: 13,
                    color: secondaryColor(context),
                  ),
                ),
                const SizedBox(height: 20),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                FilledButton(
                  onPressed: busy ? null : save,
                  child: Text(busy ? '正在保存…' : '保存'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          alias.clear();
                          color = widget.store.accountDisplays
                              .defaults(widget.account)
                              .color;
                        }),
                  child: const Text('恢复默认显示'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
