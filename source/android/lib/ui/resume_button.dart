import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'style.dart';

/// A separate hit target: surrounding artwork opens details, only this plays.
class ResumePlayButton extends StatelessWidget {
  const ResumePlayButton({
    super.key,
    required this.id,
    required this.onPressed,
  });
  final String id;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      label: '继续播放',
      button: true,
      child: CupertinoButton(
        key: ValueKey('resume-play-$id'),
        padding: EdgeInsets.zero,
        minimumSize: const Size(48, 48),
        onPressed: onPressed,
        child: AppGlassSurface(
          radius: 22,
          role: GlassRole.control,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(
              liquidGlassOf(context)
                  ? CupertinoIcons.play_fill
                  : CupertinoIcons.play_circle,
              size: liquidGlassOf(context) ? 18 : phoneValue(context, 30, 36),
              color: liquidGlassOf(context)
                  ? labelColor(context)
                  : Colors.white,
            ),
          ),
        ),
      ),
    ),
  );
}
