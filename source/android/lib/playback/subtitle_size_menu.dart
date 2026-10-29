import 'package:flutter/cupertino.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../ui/style.dart';
import '../ui/surface.dart';
import 'subtitle_size.dart';

class SubtitleSizeMenu extends StatefulWidget {
  const SubtitleSizeMenu({super.key, required this.store});
  final AppStore store;
  @override
  State<SubtitleSizeMenu> createState() => _SubtitleSizeMenuState();
}

class _SubtitleSizeMenuState extends State<SubtitleSizeMenu> {
  bool saving = false;
  String? error;
  Future<void> change(double value) async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.store.setSubtitleScale(value);
    } catch (failure) {
      if (mounted) setState(() => error = safeError(failure));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => SurfacePage(
      title: '字幕大小',
      playerMenu: true,
      playerMenuHeader: false,
      compactPlayerMenu: true,
      playerMenuWidth: 320,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          const Text('文字字幕自动适配手机和平板屏幕'),
          const SizedBox(height: 12),
          for (final value in {
            .75: '小',
            1.0: '标准',
            1.25: '大',
            1.5: '更大',
          }.entries)
            SelectionRow(
              value.value,
              selected: (widget.store.subtitleScale - value.key).abs() < .01,
              onTap: () => change(value.key),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              CupertinoButton(
                onPressed: saving || widget.store.subtitleScale <= .6
                    ? null
                    : () => change(
                        (widget.store.subtitleScale - .1).clamp(.6, 2),
                      ),
                child: const Text('缩小'),
              ),
              Text('${(widget.store.subtitleScale * 100).round()}%'),
              CupertinoButton(
                onPressed: saving || widget.store.subtitleScale >= 2
                    ? null
                    : () => change(
                        (widget.store.subtitleScale + .1).clamp(.6, 2),
                      ),
                child: const Text('放大'),
              ),
            ],
          ),
          Center(
            child: Text(
              '字幕大小预览',
              style: TextStyle(
                fontSize: subtitleFontSize(
                  MediaQuery.sizeOf(context),
                  widget.store.subtitleScale,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '主副文字字幕即时生效，退出后保留；图像字幕保持原图。',
            style: TextStyle(color: secondaryColor(context), fontSize: 12),
          ),
          if (error != null)
            Text(
              error!,
              style: const TextStyle(color: CupertinoColors.systemRed),
            ),
        ],
      ),
    ),
  );
}
