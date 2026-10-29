import 'dart:async';
import 'package:flutter/material.dart';
import '../core/server_connection.dart';
import 'control_visibility.dart';

/// One finite notice per disconnect/recovery transition. Repeated failed API
/// calls update the normal log, but do not restart the on-screen timer.
class PlaybackConnectionNotice extends StatefulWidget {
  const PlaybackConnectionNotice({
    super.key,
    required this.connection,
    this.warning,
  });
  final ServerConnection connection;
  final String? warning;
  @override
  State<PlaybackConnectionNotice> createState() =>
      _PlaybackConnectionNoticeState();
}

class _PlaybackConnectionNoticeState extends State<PlaybackConnectionNotice> {
  Timer? timer;
  String? message;
  late bool problem = widget.connection.hasProblem;
  @override
  void initState() {
    super.initState();
    widget.connection.addListener(changed);
    if (problem) {
      show(widget.connection.label);
    } else if (widget.warning != null) {
      show(widget.warning!);
    }
  }

  @override
  void didUpdateWidget(PlaybackConnectionNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!problem &&
        widget.warning != null &&
        widget.warning != oldWidget.warning) {
      show(widget.warning!);
    }
  }

  void show(String text) {
    message = text;
    timer?.cancel();
    timer = Timer(playbackControlVisibility, () {
      if (mounted) setState(() => message = null);
    });
  }

  void changed() {
    final next = widget.connection.hasProblem;
    if (next == problem) return;
    final recovered =
        problem && widget.connection.status == ServerStatus.connected;
    problem = next;
    setState(() {
      if (next) {
        show(widget.connection.label);
      } else if (recovered) {
        show('Emby 服务器已连接');
      } else {
        timer?.cancel();
        message = null;
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.connection.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => message == null
      ? const SizedBox.shrink()
      : Center(
          child: Semantics(
            liveRegion: true,
            child: Container(
              key: const Key('playback-connection-notice'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                message!,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
}
