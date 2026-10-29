import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/session.dart';

class SubtitlePositionMenu extends StatefulWidget {
  const SubtitlePositionMenu({
    super.key,
    required this.session,
    required this.onBack,
  });
  final PlaybackSession session;
  final VoidCallback onBack;
  @override
  State<SubtitlePositionMenu> createState() => _SubtitlePositionMenuState();
}

class _SubtitlePositionMenuState extends State<SubtitlePositionMenu> {
  double? value;
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final actual = await widget.session.readSubtitlePosition();
      if (mounted) setState(() => value = actual);
    } catch (failure) {
      if (mounted) {
        setState(() {
          value = null;
          error = safeError(failure);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> change(double? target, {double? delta}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = delta == null
          ? target
          : await widget.session.readSubtitlePosition() + delta;
      final actual = next == null
          ? await widget.session.resetSubtitlePosition()
          : await widget.session.setSubtitlePosition(next.clamp(0.0, 100.0));
      if (mounted) setState(() => value = actual);
    } catch (failure) {
      if (mounted) {
        setState(() {
          value = null;
          error = safeError(failure);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final ready = widget.session.ready && !widget.session.closed;
      final enabled = ready && !busy && value != null;
      return SurfacePage(
        title: '字幕位置',
        playerMenu: true,
        playerMenuHeader: false,
        compactPlayerMenu: true,
        playerMenuWidth: 360,
        onBack: widget.onBack,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            SettingsRow(
              '当前位置',
              subtitle: value == null
                  ? '未提供'
                  : widget.session.usesDefaultSubtitlePosition == true
                  ? '默认 · 画面下沿'
                  : '${value!.round()}%${widget.session.usesDefaultSubtitlePosition == null && value == 0 ? ' · 默认' : ''}',
            ),
            Text(
              '默认靠近画面下沿；可在整个屏幕调整：0% 在底部，100% 在顶部。',
              style: TextStyle(color: secondaryColor(context)),
            ),
            const SizedBox(height: 8),
            CupertinoSlider(
              key: const Key('subtitle-position-slider'),
              min: 0,
              max: 100,
              divisions: 100,
              value: value ?? 0,
              onChanged: enabled
                  ? (next) => setState(() => value = next)
                  : null,
              onChangeEnd: enabled ? change : null,
            ),
            OverflowBar(
              alignment: MainAxisAlignment.spaceEvenly,
              spacing: 8,
              children: [
                CupertinoButton(
                  onPressed: enabled ? () => change(null, delta: 5) : null,
                  child: const Text('上移 5%'),
                ),
                CupertinoButton(
                  onPressed: enabled ? () => change(null, delta: -5) : null,
                  child: const Text('下移 5%'),
                ),
              ],
            ),
            CupertinoButton(
              onPressed: enabled ? () => change(null) : null,
              child: const Text('恢复默认位置'),
            ),
            if (widget.session.selectedTrack(true) == 'no')
              Text(
                '字幕已关闭，调整不会开启字幕。',
                style: TextStyle(color: secondaryColor(context)),
              ),
            Text(
              '画面自带的烧录字幕无法单独移动。',
              style: TextStyle(color: secondaryColor(context), fontSize: 12),
            ),
            if (busy) const Center(child: CupertinoActivityIndicator()),
            if (error != null) ...[
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              CupertinoButton(
                onPressed: busy || !ready ? null : load,
                child: const Text('重新读取位置'),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class ChapterMenu extends StatefulWidget {
  const ChapterMenu({super.key, required this.session, required this.onBack});
  final PlaybackSession session;
  final VoidCallback onBack;
  @override
  State<ChapterMenu> createState() => _ChapterMenuState();
}

class _ChapterMenuState extends State<ChapterMenu> {
  List<PlaybackChapter>? chapters;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      chapters = null;
      error = null;
    });
    try {
      final value = await widget.session.readChapters();
      if (mounted) setState(() => chapters = value);
    } catch (failure) {
      if (mounted) setState(() => error = safeError(failure));
    }
  }

  Future<void> choose(PlaybackChapter chapter) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.session.seekChapter(chapter);
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) setState(() => error = safeError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final current = currentPlaybackChapter(
        chapters ?? [],
        widget.session.position,
      );
      return SurfacePage(
        title: '章节选择',
        playerMenu: true,
        playerMenuHeader: false,
        compactPlayerMenu: true,
        playerMenuWidth: 400,
        onBack: widget.onBack,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(8),
          children: [
            if (chapters == null && error == null)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CupertinoActivityIndicator()),
              ),
            if (chapters?.isEmpty == true) const SettingsRow('此资源未提供章节'),
            for (final chapter in chapters ?? <PlaybackChapter>[])
              SettingsRow(
                chapter.title,
                subtitle:
                    '${clockText(chapter.start)}${chapter.start.inMilliseconds % 1000 == 0 ? '' : '.${(chapter.start.inMilliseconds % 1000).toString().padLeft(3, '0')}'}',
                selected: chapter.index == current,
                showDisclosure: false,
                singleLine: true,
                onTap: busy || !widget.session.ready || widget.session.closed
                    ? null
                    : () => choose(chapter),
              ),
            if (error != null) ...[
              SettingsRow(error!),
              CupertinoButton(
                onPressed: busy ? null : load,
                child: const Text('重新读取章节'),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class SubtitleDelayMenu extends StatefulWidget {
  const SubtitleDelayMenu({
    super.key,
    required this.session,
    required this.onBack,
  });
  final PlaybackSession session;
  final VoidCallback onBack;
  @override
  State<SubtitleDelayMenu> createState() => _SubtitleDelayMenuState();
}

class _SubtitleDelayMenuState extends State<SubtitleDelayMenu> {
  Duration? value;
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      value = null;
      error = null;
    });
    try {
      final current = await widget.session.readSubtitleDelay();
      if (mounted) setState(() => value = current);
    } catch (failure) {
      if (mounted) setState(() => error = safeError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> change({
    Duration delta = Duration.zero,
    bool reset = false,
  }) async {
    if (busy || value == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final current = await widget.session.adjustSubtitleDelay(
        delta: delta,
        reset: reset,
      );
      if (mounted) setState(() => value = current);
    } catch (failure) {
      if (mounted) {
        setState(() {
          value = null;
          error = safeError(failure);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final enabled =
          !busy &&
          value != null &&
          widget.session.ready &&
          !widget.session.closed;
      return SurfacePage(
        title: '字幕延迟',
        playerMenu: true,
        playerMenuHeader: false,
        compactPlayerMenu: true,
        playerMenuWidth: 360,
        onBack: widget.onBack,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            SettingsRow(
              '当前延迟',
              subtitle: value == null ? '未提供' : subtitleDelayLabel(value!),
            ),
            Text(
              '正数：字幕晚出现；负数：字幕提前。',
              style: TextStyle(color: secondaryColor(context)),
            ),
            if (widget.session.selectedTrack(true) == 'no')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '字幕已关闭，调整不会开启字幕。',
                  style: TextStyle(color: secondaryColor(context)),
                ),
              ),
            const SizedBox(height: 12),
            for (final milliseconds in [100, 1000])
              OverflowBar(
                alignment: MainAxisAlignment.spaceEvenly,
                overflowAlignment: OverflowBarAlignment.center,
                spacing: 8,
                children: [
                  CupertinoButton(
                    onPressed: enabled
                        ? () => change(
                            delta: Duration(milliseconds: -milliseconds),
                          )
                        : null,
                    child: Text(
                      '提前 ${milliseconds / 1000} 秒',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  CupertinoButton(
                    onPressed: enabled
                        ? () => change(
                            delta: Duration(milliseconds: milliseconds),
                          )
                        : null,
                    child: Text(
                      '延后 ${milliseconds / 1000} 秒',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            CupertinoButton(
              onPressed: enabled ? () => change(reset: true) : null,
              child: const Text(
                '重置为 0 秒',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (busy) const Center(child: CupertinoActivityIndicator()),
            if (error != null) ...[
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              CupertinoButton(
                onPressed: busy ? null : load,
                child: const Text('重新读取延迟'),
              ),
            ],
          ],
        ),
      );
    },
  );
}
