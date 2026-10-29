import 'package:flutter/cupertino.dart';
import 'device.dart';

/// Consent lasts for this player page only; it never changes the saved switch.
class PlaybackNetworkPermission {
  PlaybackNetworkPermission({
    required this.allowed,
    Future<String> Function()? read,
  }) : read =
           read ??
           (() async =>
               await Device.channel.invokeMethod<String>('playbackNetwork') ??
               'unknown');
  final bool Function() allowed;
  final Future<String> Function() read;
  bool _confirmed = false;
  Future<bool>? _pending;

  Future<bool> authorize(BuildContext context) {
    if (allowed()) return Future.value(true);
    return _pending ??= _authorize(context).whenComplete(() => _pending = null);
  }

  Future<bool> _authorize(BuildContext context) async {
    String state;
    try {
      state = await read().timeout(const Duration(seconds: 2));
    } catch (_) {
      state = 'unknown';
    }
    if (!context.mounted) return false;
    if (allowed()) return true;
    if (state == 'unmetered') {
      _confirmed = false;
      return true;
    }
    if (_confirmed) return true;
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(
          state == 'mobile'
              ? '正在使用移动数据'
              : state == 'metered'
              ? '正在使用按流量计费的网络'
              : '暂时无法确认网络类型',
        ),
        content: const Text('播放及提前缓存视频可能消耗较多流量，是否继续本次播放？'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续播放'),
          ),
        ],
      ),
    );
    _confirmed = accepted == true;
    return _confirmed;
  }
}
