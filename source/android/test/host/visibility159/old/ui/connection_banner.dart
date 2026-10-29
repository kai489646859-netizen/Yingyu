import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/emby.dart';
import 'style.dart';

class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({
    super.key,
    required this.api,
    this.retry,
    this.busy = false,
  });
  final EmbyClient api;
  final VoidCallback? retry;
  final bool busy;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: api.connection,
    builder: (context, _) {
      if (!api.connection.hasProblem && !busy) return const SizedBox.shrink();
      final dark = Theme.of(context).brightness == Brightness.dark;
      final ink = dark ? const Color(0xFFFFCD91) : const Color(0xFF744713);
      final inset = pageInset(MediaQuery.sizeOf(context).width);
      return Semantics(
        liveRegion: true,
        child: Container(
          key: const Key('server-connection-warning'),
          margin: EdgeInsets.fromLTRB(inset, 0, inset, 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: dark ? const Color(0xE83B2921) : const Color(0xFFFFF3DE),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: dark ? const Color(0xFFB68B57) : const Color(0xFFE3C89E),
            ),
          ),
          child: Row(
            children: [
              Icon(CupertinoIcons.wifi_exclamationmark, size: 20, color: ink),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  busy && !api.connection.hasProblem
                      ? '服务器已连接，正在刷新资料…'
                      : '${api.connection.label}。${api.connection.detail ?? "请检查网络"}',
                  style: TextStyle(
                    fontSize: 12,
                    color: dark ? Colors.white : const Color(0xFF583F21),
                    height: 1.35,
                  ),
                ),
              ),
              if (retry != null) ...[
                const SizedBox(width: 12),
                CupertinoButton(
                  key: const Key('retry-server-connection'),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  onPressed: busy ? null : retry,
                  child: busy
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CupertinoActivityIndicator(color: ink),
                            const SizedBox(width: 6),
                            Text(
                              '重试中',
                              style: TextStyle(color: ink, fontSize: 13),
                            ),
                          ],
                        )
                      : Text('重试', style: TextStyle(color: ink, fontSize: 14)),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
