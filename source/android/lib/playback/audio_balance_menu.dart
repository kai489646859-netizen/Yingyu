import 'package:flutter/cupertino.dart';
import '../core/models.dart';
import '../ui/style.dart';
import '../ui/surface.dart';
import 'audio_balance.dart';
import 'session.dart';

class AudioBalanceMenu extends StatefulWidget {
  const AudioBalanceMenu({super.key, required this.session});
  final PlaybackSession session;
  @override
  State<AudioBalanceMenu> createState() => _AudioBalanceMenuState();
}

class _AudioBalanceMenuState extends State<AudioBalanceMenu> {
  bool busy = false;
  String? error;
  Future<void> choose(AudioBalance mode) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.session.setAudioBalance(mode);
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SurfacePage(
    title: '音量均衡',
    playerMenu: true,
    compactPlayerMenu: true,
    playerMenuWidth: 360,
    playerMenuHeader: false,
    child: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.all(8),
      children: [
        for (final mode in AudioBalance.values)
          IgnorePointer(
            ignoring: busy || !widget.session.ready,
            child: SelectionRow(
              mode.label,
              subtitle: mode.description,
              selected: widget.session.audioBalance == mode,
              onTap: () => choose(mode),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            error ?? (busy ? '正在应用到当前播放…' : '立即应用到当前播放，并记住选择；可随时恢复原始声音。'),
            style: TextStyle(fontSize: 12, color: secondaryColor(context)),
          ),
        ),
      ],
    ),
  );
}
