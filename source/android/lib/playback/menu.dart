// UI-only adaptation of NipaPlay CupertinoPlayerMenu and VideoSettingsMenu.
import 'package:flutter/cupertino.dart';
import '../ui/style.dart';
import '../ui/surface.dart';
import 'backend.dart';
import 'session.dart';
import 'adjustment_panels.dart';
import 'audio_balance_menu.dart';
import 'disc_title_filter.dart';
import 'controls.dart' show playbackRateText;

class PlayerMenuChoice {
  const PlayerMenuChoice(this.pane, this.value);
  final String pane;
  final Object value;
}

class PlayerMenu extends StatefulWidget {
  const PlayerMenu({
    super.key,
    required this.session,
    this.initialPane = 'root',
    required this.fit,
    required this.onToggle,
    required this.onSeek,
  });
  final PlaybackSession session;
  final String initialPane;
  final BoxFit fit;
  final VoidCallback onToggle;
  final ValueChanged<Duration> onSeek;
  @override
  State<PlayerMenu> createState() => _PlayerMenuState();
}

class _PlayerMenuState extends State<PlayerMenu> {
  late String pane = widget.initialPane;
  bool showAllDiscTitles = false;
  static const titles = {
    'root': '播放器菜单',
    'rate': '播放倍速',
    'quality': '画质',
    'audio': '音轨',
    'subtitles': '主字幕',
    'secondarySubtitles': '副字幕（文字）',
    'disc': '原盘播放',
    'chapters': '章节选择',
    'subtitleDelay': '字幕延迟',
    'subtitlePosition': '字幕位置',
    'subtitleSize': '字幕大小',
    'pictureBrightness': '画面明暗',
    'audioBalance': '音量均衡',
  };
  void choose(Object value) =>
      Navigator.pop(context, PlayerMenuChoice(pane, value));
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, widget.session.store]),
    builder: (context, _) {
      if (pane == 'chapters') {
        return ChapterMenu(
          session: widget.session,
          onBack: () => setState(() => pane = 'root'),
        );
      }
      if (pane == 'subtitleDelay') {
        return SubtitleDelayMenu(
          session: widget.session,
          onBack: () => setState(() => pane = 'root'),
        );
      }
      if (pane == 'subtitlePosition') {
        return SubtitlePositionMenu(
          session: widget.session,
          onBack: () => setState(() => pane = 'root'),
        );
      }
      if (pane == 'pictureBrightness') {
        return PictureBrightnessMenu(
          session: widget.session,
          onBack: () => setState(() => pane = 'root'),
        );
      }
      if (pane == 'audioBalance' && widget.session.hasAudioBalance) {
        return AudioBalanceMenu(session: widget.session);
      }
      final entries = rows();
      return SurfacePage(
        title: titles[pane]!,
        playerMenu: true,
        compactPlayerMenu: true,
        playerMenuWidth: selectionWidth(entries),
        playerMenuHeader: pane == 'root',
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          // The old root toolbar cannot fit the narrower choice panel. Fade
          // the incoming pane without laying the outgoing pane out at its width.
          layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
          child: ListView(
            key: ValueKey(pane),
            shrinkWrap: true,
            padding: pane == 'root'
                ? const EdgeInsets.fromLTRB(16, 8, 16, 24)
                : const EdgeInsets.all(8),
            physics: const BouncingScrollPhysics(),
            children: entries,
          ),
        ),
      );
    },
  );

  double selectionWidth(List<Widget> entries) {
    double textWidth(String text, double size, {FontWeight? weight}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: CupertinoTheme.of(context).textTheme.actionTextStyle.copyWith(
            fontSize: size,
            fontWeight: weight ?? FontWeight.normal,
          ),
        ),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    var content = 0.0;
    for (final entry in entries) {
      final (title, subtitle) = switch (entry) {
        SelectionRow(:final title, :final subtitle) => (title, subtitle),
        SettingsRow(:final title, :final subtitle) => (title, subtitle),
        _ => ('', null),
      };
      var width = textWidth(title, phoneValue(context, 15, 16));
      if (subtitle != null) {
        final secondary = textWidth(subtitle, 12);
        if (secondary > width) width = secondary;
      }
      width += phoneValue(context, 28, 40);
      if (entry is SettingsRow) {
        if (entry.icon != null) {
          width += phoneValue(context, 26, 28) + phoneValue(context, 10, 14);
        }
        if (entry.onTap != null &&
            entry.showDisclosure &&
            entry.trailing == null) {
          width += 12 + 15;
        }
      }
      if (entry is Padding && entry.child is Text) {
        final text = entry.child! as Text;
        width =
            textWidth(
              text.data ?? '',
              text.style?.fontSize ?? 14,
              weight: text.style?.fontWeight,
            ) +
            entry.padding.resolve(Directionality.of(context)).horizontal;
      }
      if (width > content) content = width;
    }
    final measured = content.ceilToDouble() + (pane == 'root' ? 32 : 16) + 2;
    // Widen for one-line labels; only screen-limited text is ellipsized.
    final media = MediaQuery.of(context);
    final available = (media.size.width - media.padding.horizontal - 40).clamp(
      0.0,
      double.infinity,
    );
    return measured.clamp(48.0, double.infinity).clamp(0.0, available);
  }

  Widget heading(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
    child: Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: secondaryColor(context),
      ),
    ),
  );
  Widget tile(String id, IconData icon, {String? value}) => SettingsRow(
    titles[id]!,
    icon: icon,
    subtitle: value,
    singleLine: true,
    onTap: () => setState(() => pane = id),
  );
  List<Widget> rows() {
    final session = widget.session;
    if (pane == 'root') {
      return [
        SettingsRow(
          '片头片尾',
          icon: CupertinoIcons.forward,
          singleLine: true,
          onTap: session.ready
              ? () => Navigator.pop(
                  context,
                  const PlayerMenuChoice('intro', true),
                )
              : null,
        ),
        if (session.hasChapters) tile('chapters', CupertinoIcons.list_bullet),
        if (session.hasSubtitleDelay)
          tile('subtitleDelay', CupertinoIcons.time),
        if (session.hasSubtitlePosition)
          tile('subtitlePosition', CupertinoIcons.arrow_up_down),
        SettingsRow(
          '字幕大小',
          icon: CupertinoIcons.textformat_size,
          onTap: () => Navigator.pop(
            context,
            const PlayerMenuChoice('subtitleSize', true),
          ),
        ),
        if (session.hasPictureBrightness)
          tile('pictureBrightness', CupertinoIcons.brightness),
        if (session.hasAudioBalance)
          tile(
            'audioBalance',
            CupertinoIcons.waveform,
            value: session.audioBalance.label,
          ),
        if (session.backend is DiscNavigationBackend)
          tile('disc', CupertinoIcons.square_stack_3d_up),
      ];
    }
    if (pane == 'quality') {
      return [
        SelectionRow('原画', selected: true, onTap: () => choose('original')),
      ];
    }
    if (pane == 'rate') {
      if (!session.canChangeSpeed) {
        return [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '加载完成后可调整倍速',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ];
      }
      return [
        for (final rate in [3.0, 2.0, 1.5, 1.25, 1.0, .75, .5])
          SelectionRow(
            playbackRateText(rate),
            selected: (session.pendingSpeed ?? session.speed) == rate,
            onTap: () => choose(rate),
          ),
      ];
    }
    if (pane == 'secondarySubtitles') {
      return [
        const SettingsRow('副字幕在上方显示；延迟与主字幕共用'),
        for (final option in session.secondaryOptions)
          SelectionRow(
            option.label,
            selected: session.secondaryId == option.id,
            onTap: () => choose(option),
          ),
      ];
    }
    if (pane == 'audio' || pane == 'subtitles') {
      final subtitles = pane == 'subtitles';
      final options = session.trackOptions(subtitles);
      return [
        if (subtitles) ...[
          SettingsRow(
            '字幕大小',
            icon: CupertinoIcons.textformat_size,
            onTap: () => Navigator.pop(
              context,
              const PlayerMenuChoice('subtitleSize', true),
            ),
          ),
          SettingsRow(
            '导入本地字幕',
            icon: CupertinoIcons.folder,
            onTap: () => Navigator.pop(
              context,
              const PlayerMenuChoice('subtitleImport', true),
            ),
          ),
        ],
        if (!options.any((t) => !t.control))
          const SettingsRow('没有可用轨道', singleLine: true),
        for (final option in options)
          SelectionRow(
            option.label,
            subtitle:
                !subtitles &&
                    !option.control &&
                    options
                            .where((t) => !t.control && t.label == option.label)
                            .length >
                        1
                ? (option.title.trim().isEmpty
                      ? '音轨 ${option.id}'
                      : option.title)
                : null,
            selected: session.selectedTrack(subtitles) == option.id,
            onTap: () => choose(option),
          ),
        if (subtitles) ...[
          SettingsRow(
            '副字幕（文字）',
            icon: CupertinoIcons.textformat,
            onTap: () => setState(() => pane = 'secondarySubtitles'),
          ),
          SettingsRow(
            '在线字幕搜索',
            icon: CupertinoIcons.search,
            onTap: () => Navigator.pop(
              context,
              const PlayerMenuChoice('subtitleSearch', true),
            ),
          ),
        ],
      ];
    }
    final backend = session.backend;
    if (pane == 'disc' && backend is DiscNavigationBackend) {
      final disc = backend as DiscNavigationBackend;
      final listing = discTitleListing(
        disc.discTitles,
        selectedPlaylist: disc.selectedDiscPlaylist,
        showAll: showAllDiscTitles,
      );
      return [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            'STRM 仍由 Emby 解析；链接隐藏原盘格式时可手动指定',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: secondaryColor(context)),
          ),
        ),
        SelectionRow('自动识别', onTap: () => choose(-1)),
        SelectionRow('按蓝光 ISO 读取', onTap: () => choose(-2)),
        SelectionRow('按 BDMV HTTP 目录读取', onTap: () => choose(-3)),
        if (disc.discTitles.isNotEmpty) heading('自动识别主片；切换标题从头播放'),
        for (final title in listing.titles)
          SelectionRow(
            title.label,
            subtitle:
                '${title.clips.length} 个片段 · ${title.chapters.length} 个章节',
            selected: title.playlist == disc.selectedDiscPlaylist,
            onTap: () => choose(title.playlist),
          ),
        if (listing.hiddenCount > 0)
          SelectionRow(
            '显示全部播放列表（另 ${listing.hiddenCount} 项）',
            subtitle: '已收起不足 3 分钟的短播放列表',
            onTap: () => setState(() => showAllDiscTitles = true),
          )
        else if (showAllDiscTitles)
          SelectionRow(
            '收起短播放列表',
            onTap: () => setState(() => showAllDiscTitles = false),
          ),
      ];
    }
    return const [MessagePanel('没有可用条目')];
  }
}
