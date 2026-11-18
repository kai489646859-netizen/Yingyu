import 'dart:io';
import 'package:flutter/material.dart';
import '../core/app_update.dart';
import '../core/log.dart';

class AndroidUpdatePanel extends StatefulWidget {
  const AndroidUpdatePanel({super.key, this.log});
  final DiagnosticLog? log;
  @override
  State<AndroidUpdatePanel> createState() => _AndroidUpdatePanelState();
}

class _AndroidUpdatePanelState extends State<AndroidUpdatePanel>
    with WidgetsBindingObserver {
  final update = AndroidAppUpdate.shared;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      update.observeInstallState(true);
      update.restore();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) update.observeInstallState(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) update.refreshInstallState();
  }

  String size(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final log = widget.log;
    void recordUpdate(String detail) => log?.add(LogArea.app, '应用更新 · $detail');
    return ListenableBuilder(
      listenable: update,
      builder: (_, _) {
        final asset = update.release;
        final busy = update.checking || update.downloading || update.installing;
        return Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (asset != null)
                Text('Android ${asset.version} · ${size(asset.size)}'),
              if (asset != null &&
                  (update.bytes > 0 || update.downloading)) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: (update.bytes / asset.size).clamp(0, 1),
                ),
                Text('${size(update.bytes)} / ${size(asset.size)}'),
              ],
              if (update.message case final text?) Text(text),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => update.check(diagnostic: recordUpdate),
                    child: Text(update.checking ? '正在检查…' : '检查更新'),
                  ),
                  if (asset != null)
                    FilledButton(
                      onPressed: update.downloading
                          ? update.pause
                          : busy
                          ? null
                          : update.verified
                          ? update.install
                          : () => update.download(diagnostic: recordUpdate),
                      child: Text(
                        update.downloading
                            ? '暂停下载'
                            : update.verified
                            ? '安装更新'
                            : update.bytes > 0
                            ? '继续下载'
                            : '下载安装包',
                      ),
                    ),
                  if (asset != null && update.bytes > 0 && !busy)
                    TextButton(
                      onPressed: update.discard,
                      child: const Text('删除下载'),
                    ),
                ],
              ),
              const Text('使用映屿的正式安卓发布包，由系统确认覆盖安装。'),
            ],
          ),
        );
      },
    );
  }
}
