import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/server_address.dart';
import 'style.dart';
import 'anchored_menu.dart';
import 'poster_press.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.login,
    this.loginNamed,
    this.initialServer = '',
    this.initialUsername = '',
    this.message,
    this.fixedIdentity = false,
    this.back = false,
  });
  final Future<void> Function(String, String, String) login;
  final Future<void> Function(String, String, String, String)? loginNamed;
  final String initialServer, initialUsername;
  final String? message;
  final bool fixedIdentity, back;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final server = TextEditingController(),
      port = TextEditingController(text: '8096'),
      path = TextEditingController();
  final name = TextEditingController(), password = TextEditingController();
  late final username = TextEditingController(text: widget.initialUsername);
  String protocol = 'http';
  bool busy = false, hidden = true;
  String? error;
  @override
  void initState() {
    super.initState();
    if (widget.initialServer.isNotEmpty) applyAddress(widget.initialServer);
  }

  void applyAddress(String text, {bool preserveSelection = false}) {
    final value = ServerAddress.parse(
      text,
      defaultProtocol: preserveSelection ? protocol : 'http',
      defaultPort: preserveSelection ? port.text : '8096',
    );
    protocol = value.protocol;
    server.text = value.host;
    port.text = value.port;
    path.text = value.path;
  }

  @override
  void dispose() {
    for (final field in [server, port, path, name, password, username]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> connect() async {
    if (busy) return;
    FocusScope.of(context).unfocus();
    String address;
    try {
      if (server.text.contains('://') ||
          server.text.contains('/') ||
          server.text.trim().startsWith('[') ||
          RegExp(r'^[^:]+:\d+$').hasMatch(server.text.trim())) {
        applyAddress(server.text, preserveSelection: true);
      }
      address = ServerAddress(
        protocol,
        server.text,
        port.text,
        path.text,
      ).address;
      if (username.text.trim().isEmpty) throw const AppFailure('请输入用户名');
    } catch (e) {
      setState(() => error = safeError(e));
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.loginNamed != null) {
        await widget.loginNamed!(
          address,
          username.text.trim(),
          password.text,
          name.text.trim(),
        );
      } else {
        await widget.login(address, username.text.trim(), password.text);
      }
      if (mounted) {
        password.clear();
      }
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    String label,
    String key,
    TextEditingController controller, {
    String? hint,
    bool secret = false,
    bool identity = false,
    TextInputType keyboard = TextInputType.text,
  }) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: phoneValue(context, 14, 18),
      vertical: phoneValue(context, 6, 9),
    ),
    child: Row(
      children: [
        SizedBox(
          width: phoneValue(context, 56, 72),
          child: Text(
            label,
            style: TextStyle(fontSize: 14, color: secondaryColor(context)),
          ),
        ),
        Expanded(
          child: TextField(
            key: ValueKey(key),
            controller: controller,
            style: phoneLayout(context)
                ? TextStyle(fontSize: 15, color: labelColor(context))
                : null,
            readOnly: busy || (identity && widget.fixedIdentity),
            obscureText: secret && hidden,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: keyboard,
            textInputAction: secret
                ? TextInputAction.done
                : TextInputAction.next,
            onSubmitted: secret ? (_) => connect() : null,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: groupedColor(context),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 14,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              suffixIcon: secret
                  ? IconButton(
                      tooltip: hidden ? '显示密码' : '隐藏密码',
                      key: const Key('login-password-visibility'),
                      onPressed: () => setState(() => hidden = !hidden),
                      icon: Icon(
                        hidden ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                        size: 21,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ],
    ),
  );

  Widget heading() => Padding(
    padding: EdgeInsets.fromLTRB(
      phoneValue(context, 20, 24),
      phoneValue(context, 8, 14),
      phoneValue(context, 20, 24),
      phoneValue(context, 16, 22),
    ),
    child: Row(
      children: [
        Container(
          width: phoneValue(context, 44, 56),
          height: phoneValue(context, 44, 56),
          decoration: BoxDecoration(
            color: accentColor(context).withValues(alpha: .12),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(
            CupertinoIcons.play_rectangle_fill,
            color: accentColor(context),
            size: 29,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.fixedIdentity ? '欢迎回来' : '连接你的媒体库',
                style: TextStyle(
                  fontSize: phoneValue(context, 19, 22),
                  fontWeight: FontWeight.w600,
                  letterSpacing: .3,
                  color: labelColor(context),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                widget.fixedIdentity ? '验证账号，继续观看' : '填写服务器信息，开始浏览与观看',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: secondaryColor(context),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget formCard({required List<Widget> children}) => Padding(
    padding: EdgeInsets.fromLTRB(
      phoneValue(context, 16, 20),
      0,
      phoneValue(context, 16, 20),
      phoneValue(context, 12, 16),
    ),
    child: ColoredBox(
      color: groupedColor(context),
      child: Container(
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: accentColor(context).withValues(alpha: .16),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0)
                      const Divider(height: .5, indent: 20, endIndent: 20),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final protocolMenu = AnchoredMenuController();
  Widget protocolField() => PosterPressFeedback(
    active: !busy && !widget.fixedIdentity,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: busy || widget.fixedIdentity ? null : protocolMenu.open,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: phoneValue(context, 14, 18),
          vertical: phoneValue(context, 6, 9),
        ),
        child: Row(
          children: [
            SizedBox(
              width: phoneValue(context, 56, 72),
              child: Text(
                '协议',
                style: TextStyle(fontSize: 14, color: secondaryColor(context)),
              ),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.only(left: 14, right: 4),
                decoration: BoxDecoration(
                  color: groupedColor(context),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(protocol.toUpperCase())),
                    AnchoredMenuButton<String>(
                      id: 'server-protocol',
                      label: '选择协议',
                      controller: protocolMenu,
                      enabled: !busy && !widget.fixedIdentity,
                      iconSize: 18,
                      expandedIcon: CupertinoIcons.chevron_down,
                      menuWidth: compactMenuWidth(context, ['HTTP', 'HTTPS']),
                      items: (_) => [
                        for (final value in ['http', 'https'])
                          PopupMenuItem(
                            value: value,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Semantics(
                              selected: protocol == value,
                              child: Text(
                                value.toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: protocol == value
                                      ? accentColor(context)
                                      : labelColor(context),
                                ),
                              ),
                            ),
                          ),
                      ],
                      onSelected: (value) => setState(() {
                        protocol = value;
                        if (port.text == '8096' || port.text == '8920') {
                          port.text = value == 'http' ? '8096' : '8920';
                        }
                      }),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.fixedIdentity ? '重新登录' : '添加 Emby'),
        automaticallyImplyLeading: widget.back,
      ),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusScope.of(context).unfocus(),
          child: PageList(
            storageKey: const PageStorageKey('login-page'),
            children: [
              heading(),
              formCard(
                children: [
                  field('名称', 'server-name', name, hint: '选填，作为本机账号备注'),
                  protocolField(),
                  field(
                    '地址 *',
                    'account-server',
                    server,
                    hint: 'IP 或域名，例如 192.168.1.10',
                    identity: true,
                    keyboard: TextInputType.url,
                  ),
                  field(
                    '端口',
                    'server-port',
                    port,
                    identity: true,
                    keyboard: TextInputType.number,
                  ),
                  field(
                    '路径',
                    'server-path',
                    path,
                    hint: '选填，例如 /proxy/emby',
                    identity: true,
                    keyboard: TextInputType.url,
                  ),
                  field(
                    '用户名 *',
                    'account-username',
                    username,
                    hint: '必填',
                    identity: true,
                  ),
                  field(
                    '密码',
                    'account-password',
                    password,
                    hint: '选填',
                    secret: true,
                  ),
                ],
              ),
              if (error != null || widget.message != null)
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    error ?? widget.message!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(
                  '直接连接你填写的 Emby 地址，支持局域网 IP 与域名。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: secondaryColor(context),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                child: FilledButton(
                  key: const Key('account-login-submit'),
                  onPressed: busy ? null : connect,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(busy ? '正在登录…' : '连接并登录'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
