import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/account_controller.dart';
import '../core/accounts.dart';
import '../core/models.dart';
import 'style.dart';
import 'surface.dart';
import 'account_avatar.dart';
import 'account_display_editor.dart';
import 'login.dart';
import 'anchored_menu.dart';
export 'account_avatar.dart';

Future<void> showAccountLogin(
  BuildContext context,
  AccountController controller, {
  SavedAccount? account,
}) => Navigator.of(context).push<void>(
  CupertinoPageRoute(
    builder: (_) => AccountLoginPage(controller: controller, account: account),
  ),
);

Future<void> showAccountPicker(
  BuildContext context,
  AccountController controller, {
  bool allowReorder = false,
}) => showSurface<void>(
  context,
  (_) => AccountPicker(controller: controller, allowReorder: allowReorder),
);

class AccountPicker extends StatefulWidget {
  const AccountPicker({
    super.key,
    required this.controller,
    this.allowReorder = false,
  });
  final AccountController controller;
  final bool allowReorder;
  @override
  State<AccountPicker> createState() => _AccountPickerState();
}

class _AccountPickerState extends State<AccountPicker> {
  String? error, workingId;
  List<SavedAccount>? ordering;
  Future<void> editOrder() async {
    if (ordering == null) {
      setState(() => ordering = List.of(controller.accounts));
      return;
    }
    try {
      await controller.reorder(ordering!.map((a) => a.id).toList());
      if (mounted) {
        setState(() {
          ordering = null;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
    }
  }

  AccountController get controller => widget.controller;
  Future<void> choose(SavedAccount account) async {
    if (controller.busy) return;
    if (account.needsLogin) {
      await showAccountLogin(context, controller, account: account);
      if (mounted &&
          controller.connected &&
          controller.selected?.id == account.id) {
        Navigator.pop(context);
      }
      return;
    }
    setState(() {
      error = null;
      workingId = account.id;
    });
    try {
      await controller.switchTo(account);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = '${accountName(account.session)}：${safeError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => workingId = null);
    }
  }

  Future<void> remove(SavedAccount account) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('从本机移除账号？'),
        content: Text(
          '${accountName(account.session)}\n${account.session.base}\n\n'
          '仅移除这台设备的登录。服务器账号、观看记录和本机缓存保留，再次使用需要登录。',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      error = null;
      workingId = account.id;
    });
    try {
      await controller.remove(account);
      if (mounted) setState(() => error = controller.error);
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
    } finally {
      if (mounted) setState(() => workingId = null);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, controller.store]),
    builder: (context, _) {
      final screen = MediaQuery.sizeOf(context);
      final safe = MediaQuery.paddingOf(context);
      final wide = screen.width > screen.height;
      return PopScope(
        canPop: !controller.busy,
        child: Align(
          alignment: wide ? Alignment.center : Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              12 + safe.left,
              12 + safe.top,
              12 + safe.right,
              12 + safe.bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 480,
                maxHeight: math.min(610, screen.height - safe.vertical - 24),
              ),
              child: Material(
                key: const Key('account-picker'),
                color: groupedColor(context),
                borderRadius: BorderRadius.circular(24),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 8, 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '切换账号',
                              style: TextStyle(
                                fontSize: phoneValue(context, 18, 21),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (widget.allowReorder &&
                              controller.accounts.length > 1)
                            TextButton(
                              key: const Key('account-order'),
                              onPressed: controller.busy ? null : editOrder,
                              child: Text(ordering == null ? '排序' : '完成'),
                            ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: controller.busy
                                ? null
                                : () => Navigator.pop(context),
                            icon: const Icon(CupertinoIcons.xmark, size: 19),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: ordering != null
                          ? ReorderableListView.builder(
                              key: const Key('account-order-list'),
                              shrinkWrap: true,
                              buildDefaultDragHandles: false,
                              // Keep the row's own rounded surface while dragging.
                              // The default Material proxy adds a rectangular lift.
                              proxyDecorator: (child, index, animation) => child,
                              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                              itemCount: ordering!.length,
                              onReorderItem: (from, to) {
                                if (controller.busy) return;
                                setState(
                                  () => ordering!.insert(
                                    to,
                                    ordering!.removeAt(from),
                                  ),
                                );
                              },
                              itemBuilder: (context, index) => KeyedSubtree(
                                key: ValueKey(ordering![index].id),
                                child: accountRow(
                                  ordering![index],
                                  orderIndex: index,
                                ),
                              ),
                            )
                          : ListView(
                              shrinkWrap: true,
                              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                              children: [
                                if (controller.accounts.isEmpty)
                                  const Padding(
                                    padding: EdgeInsets.all(20),
                                    child: Text('还没有保存的账号'),
                                  ),
                                for (final account in controller.accounts)
                                  accountRow(account),
                                if (error != null)
                                  Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Text(
                                      error!,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    const Divider(height: 1),
                    if (ordering != null && error != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: TextButton.icon(
                        key: const Key('add-account'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(double.infinity, 48),
                        ),
                        onPressed: controller.busy || ordering != null
                            ? null
                            : () async {
                                final before = controller.api;
                                await showAccountLogin(context, controller);
                                if (context.mounted &&
                                    controller.api != before &&
                                    controller.connected) {
                                  Navigator.pop(context);
                                }
                              },
                        icon: const Icon(CupertinoIcons.person_badge_plus),
                        label: const Text('添加账号'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget accountRow(SavedAccount account, {int? orderIndex}) {
    final current =
        controller.connected && controller.selected?.id == account.id;
    final s = account.session;
    final display = controller.store.accountDisplays.read(s);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: current
            ? accentColor(context).withValues(alpha: .11)
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                key: ValueKey('choose-account-${account.id}'),
                borderRadius: BorderRadius.circular(16),
                onTap: controller.busy || ordering != null
                    ? null
                    : () => choose(account),
                child: Semantics(
                  selected: current,
                  button: true,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      12,
                      phoneValue(context, 10, 14),
                      0,
                      phoneValue(context, 10, 14),
                    ),
                    child: Row(
                      children: [
                        AccountAvatar(
                          s,
                          size: phoneValue(context, 32, 40),
                          display: display,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                display.name(s),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (display.alias.isNotEmpty)
                                Text(
                                  '账号：${accountName(s)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: secondaryColor(context),
                                  ),
                                ),
                              const SizedBox(height: 3),
                              Text(
                                s.base.toString(),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: secondaryColor(context),
                                ),
                              ),
                              if (account.needsLogin)
                                Text(
                                  '登录已过期 · 点击重新登录',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              if (current)
                                Text(
                                  '当前使用',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: accentColor(context),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (workingId == account.id && controller.busy)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: CupertinoActivityIndicator(),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (orderIndex != null)
              ReorderableDragStartListener(
                index: orderIndex,
                enabled: !controller.busy,
                child: Semantics(
                  label: '拖动调整账号顺序',
                  child: SizedBox(
                    width: 44,
                    height: 48,
                    child: Icon(
                      CupertinoIcons.line_horizontal_3,
                      color: accentColor(context),
                    ),
                  ),
                ),
              )
            else
              AnchoredMenuButton<String>(
                id: 'account-manage-${account.id}',
                label: '管理 ${accountName(s)}',
                menuWidth: compactMenuWidth(context, ['备注与头像', '从本机移除']),
                enabled: !controller.busy,
                icon: CupertinoIcons.ellipsis,
                iconSize: 20,
                color: secondaryColor(context),
                items: (_) => [
                  for (final action in const {
                    'edit': '备注与头像',
                    'remove': '从本机移除',
                  }.entries)
                    PopupMenuItem(
                      value: action.key,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        action.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                ],
                onSelected: (value) {
                  if (value == 'remove') {
                    remove(account);
                  } else {
                    Navigator.push<void>(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => AccountDisplayEditor(
                          store: controller.store,
                          account: s,
                        ),
                      ),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class AccountLoginPage extends StatelessWidget {
  const AccountLoginPage({super.key, required this.controller, this.account});
  final AccountController controller;
  final SavedAccount? account;
  @override
  Widget build(BuildContext context) {
    Future<void> submit(
      String server,
      String user,
      String password,
      String name,
    ) async {
      await controller.login(
        server,
        user,
        password,
        replacing: account,
        alias: name,
      );
      if (context.mounted) Navigator.pop(context);
    }

    return LoginPage(
      back: true,
      fixedIdentity: account != null,
      initialServer: account?.session.base.toString() ?? '',
      initialUsername: account?.session.username ?? '',
      login: (s, u, p) => submit(s, u, p, ''),
      loginNamed: submit,
    );
  }
}
