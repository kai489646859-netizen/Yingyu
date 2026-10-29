import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/log.dart';
import '../ui/style.dart';
import '../ui/surface.dart';
import 'controls.dart';
import 'playback_adjustments.dart';
import 'session.dart';

class PictureBrightnessMenu extends StatefulWidget {
  const PictureBrightnessMenu({
    super.key,
    required this.session,
    required this.onBack,
  });
  final PlaybackSession session;
  final VoidCallback onBack;
  @override
  State<PictureBrightnessMenu> createState() => _PictureBrightnessMenuState();
}

class _PictureBrightnessMenuState extends State<PictureBrightnessMenu> {
  double? value;
  bool busy = true;
  String? error;
  bool shadowBusy = false;
  Future<void> changeShadow(double next) async {
    if (busy || shadowBusy) return;
    setState(() {
      shadowBusy = true;
      error = null;
    });
    try {
      await widget.session.setShadowEnhancement(next);
    } catch (failure) {
      if (mounted) setState(() => error = safeError(failure));
    } finally {
      if (mounted) setState(() => shadowBusy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final actual = await widget.session.readPictureBrightness();
      if (mounted) setState(() => value = actual);
    } catch (failure) {
      if (mounted) setState(() => error = safeError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> change(double next) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final actual = await widget.session.setPictureBrightness(next);
      if (mounted) setState(() => value = actual);
    } catch (failure) {
      if (mounted) setState(() => error = safeError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) => SurfacePage(
      title: '画面明暗',
      playerMenu: true,
      playerMenuHeader: false,
      compactPlayerMenu: true,
      playerMenuWidth: 360,
      onBack: widget.onBack,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          Text('整体亮度增强', style: TextStyle(color: secondaryColor(context))),
          const SizedBox(height: 8),
          for (final entry in {
            0.0: '原始画面',
            5.0: '轻度提亮',
            10.0: '中度提亮',
            15.0: '较强提亮',
          }.entries)
            IgnorePointer(
              ignoring:
                  busy ||
                  shadowBusy ||
                  !widget.session.ready ||
                  widget.session.closed,
              child: SelectionRow(
                entry.value,
                selected: value != null && (value! - entry.key).abs() < .001,
                onTap: () => change(entry.key),
              ),
            ),
          const SizedBox(height: 8),
          if (widget.session.hasShadowEnhancement) ...[
            Text('暗部增强', style: TextStyle(color: secondaryColor(context))),
            const SizedBox(height: 8),
            for (final entry in {
              0.0: '关闭',
              0.25: '轻度',
              0.5: '中度',
              0.75: '较强',
            }.entries)
              IgnorePointer(
                ignoring:
                    busy ||
                    shadowBusy ||
                    !widget.session.ready ||
                    widget.session.closed,
                child: SelectionRow(
                  entry.value,
                  selected: widget.session.shadowEnhancement == entry.key,
                  onTap: () => changeShadow(entry.key),
                ),
              ),
            const SizedBox(height: 8),
          ],
          Text(
            '适用于普通影片、HDR、杜比与原盘，暂停时也可预览。暗部增强可单独使用，整体亮度增强调整整幅画面；默认关闭，切换影片后恢复原始画面。',
            style: TextStyle(color: secondaryColor(context)),
          ),
          SizedBox(
            height: 20,
            child: busy
                ? const Center(child: CupertinoActivityIndicator())
                : null,
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );
}

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
  double? confirmed;
  bool busy = true;
  bool previewBusy = false;
  bool pendingGeometry = false;
  bool geometryReading = false;
  Timer? geometryTimer;
  double? pendingPreview;
  int previewRevision = 0;
  String? error;
  void watchGeometry() {
    if (!mounted) return;
    if (!pendingGeometry ||
        widget.session.usesDefaultSubtitlePosition != true ||
        !widget.session.ready ||
        widget.session.closed ||
        widget.session.background) {
      geometryTimer?.cancel();
      geometryTimer = null;
      return;
    }
    if (geometryReading || previewBusy || geometryTimer?.isActive == true) {
      return;
    }
    geometryTimer = Timer(const Duration(milliseconds: 250), () {
      geometryTimer = null;
      if (mounted &&
          !busy &&
          !previewBusy &&
          widget.session.ready &&
          !widget.session.closed &&
          !widget.session.background) {
        unawaited(load(quiet: true));
      }
    });
  }

  @override
  void initState() {
    super.initState();
    widget.session.addListener(watchGeometry);
    load();
  }

  Future<void> load({bool quiet = false}) async {
    if (geometryReading) return;
    geometryReading = true;
    setState(() {
      if (!quiet) busy = true;
      error = null;
    });
    try {
      final actual = await widget.session.readSubtitlePosition();
      if (mounted) {
        setState(() {
          value = confirmed = actual;
          pendingGeometry = false;
        });
      }
    } on SubtitlePositionPending {
      if (mounted) {
        setState(() {
          value = null;
          pendingGeometry = true;
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          pendingGeometry = false;
          value = null;
          error = safeError(failure);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
      geometryReading = false;
      watchGeometry();
    }
  }

  Future<void> change(double? target, {double? delta}) async {
    if (busy || previewBusy) return;
    final previous = value;
    setState(() {
      previewBusy = true;
      error = null;
    });
    try {
      final next = delta == null
          ? target
          : await widget.session.readSubtitlePosition() + delta;
      final actual = next == null
          ? await widget.session.resetSubtitlePosition()
          : await widget.session.setSubtitlePosition(next.clamp(0.0, 100.0));
      if (mounted) {
        setState(() {
          value = confirmed = actual;
          pendingGeometry = false;
        });
      }
    } on SubtitlePositionPending {
      if (mounted) {
        setState(() {
          value = confirmed = null;
          pendingGeometry = true;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          value = previous;
          error = safeError(failure);
        });
      }
    } finally {
      if (mounted) {
        setState(() => previewBusy = false);
        if (pendingPreview != null) unawaited(drainPreview());
        watchGeometry();
      }
    }
  }

  // At most one native transaction and the latest unsent drag value. Updating
  // the thumb never disables its gesture, and old acknowledgements cannot
  // move it back while the user's finger is still moving.
  void preview(double next) {
    if (busy || !widget.session.ready || widget.session.closed) return;
    setState(() {
      value = next;
      error = null;
      pendingPreview = next;
      previewRevision++;
    });
    if (!previewBusy) unawaited(drainPreview());
  }

  Future<void> drainPreview() async {
    if (previewBusy) return;
    previewBusy = true;
    try {
      while (mounted && pendingPreview != null) {
        final target = pendingPreview!;
        final revision = previewRevision;
        pendingPreview = null;
        try {
          final actual = await widget.session.setSubtitlePosition(target);
          if (!mounted) return;
          confirmed = actual;
          pendingGeometry = false;
          if (revision == previewRevision) setState(() => value = actual);
        } catch (failure) {
          if (!mounted) return;
          widget.session.store.log.add(
            LogArea.player,
            '字幕位置调整失败：${safeError(failure)}；请求=${target.toStringAsFixed(1)}%',
            level: LogLevel.warning,
          );
          if (revision == previewRevision) {
            pendingPreview = null;
            setState(() {
              value = confirmed;
              error = safeError(failure);
            });
          }
        }
      }
    } finally {
      previewBusy = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    geometryTimer?.cancel();
    widget.session.removeListener(watchGeometry);
    pendingPreview = null;
    previewRevision++;
    super.dispose();
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
                  ? pendingGeometry
                        ? '等待字幕出现，出现后即可调整'
                        : '未提供'
                  : widget.session.usesDefaultSubtitlePosition == true
                  ? widget.session.usesDiscSubtitlePosition
                        ? '默认 · 原盘字幕排版'
                        : '默认 · 画面下沿'
                  : '${value!.round()}%${widget.session.usesDefaultSubtitlePosition == null && value == 0 ? ' · 默认' : ''}',
            ),
            Text(
              widget.session.usesDiscSubtitlePosition
                  ? '默认沿用原盘字幕自身排版；手动调整对${widget.session.subtitlePositionMemoryLabel}生效，与外挂字幕分别记忆。0% 在屏幕底部，100% 在顶部。'
                  : '默认靠近画面下沿；调整后仅对${widget.session.subtitlePositionMemoryLabel}记忆。0% 在屏幕底部，100% 在顶部。',
              style: TextStyle(color: secondaryColor(context)),
            ),
            const SizedBox(height: 8),
            if (pendingGeometry || widget.session.usesDiscSubtitlePosition)
              SizedBox(
                height: MediaQuery.textScalerOf(context).scale(13) * 3.4,
                child: Row(
                  children: [
                    const Icon(CupertinoIcons.text_bubble, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        pendingGeometry
                            ? '正在等待字幕的位置数据。字幕出现后，调整条会自动启用。'
                            : enabled
                            ? '字幕位置已就绪，可以拖动调整'
                            : '正在读取字幕位置',
                      ),
                    ),
                  ],
                ),
              ),
            CupertinoSlider(
              key: const Key('subtitle-position-slider'),
              min: 0,
              max: 100,
              divisions: 100,
              value: value ?? 50,
              onChanged: enabled ? preview : null,
              onChangeStart: enabled
                  ? (next) => widget.session.store.log.add(
                      LogArea.player,
                      '字幕位置拖动开始：${next.toStringAsFixed(1)}%',
                    )
                  : null,
              onChangeEnd: enabled
                  ? (next) => widget.session.store.log.add(
                      LogArea.player,
                      '字幕位置拖动结束：${next.toStringAsFixed(1)}；确认=${confirmed?.toStringAsFixed(1) ?? '等待'}',
                    )
                  : null,
            ),
            OverflowBar(
              alignment: MainAxisAlignment.spaceEvenly,
              spacing: 8,
              children: [
                CupertinoButton(
                  // Keep the controls visually stable during native replies.
                  // change() still guards against overlapping transactions.
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
            SizedBox(
              height: 20,
              child: busy
                  ? const Center(child: CupertinoActivityIndicator())
                  : null,
            ),
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
            SizedBox(
              height: 20,
              child: busy
                  ? const Center(child: CupertinoActivityIndicator())
                  : null,
            ),
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
