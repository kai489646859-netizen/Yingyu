// Controls forward to PlaybackSession; layout never owns playback state.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/playback/player_status.dart';

String clockText(Duration d) =>
    '${d.inHours > 0 ? '${d.inHours}:' : ''}'
    '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:'
    '${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

String playbackRateText(double rate) =>
    '${rate.toStringAsFixed((rate * 10).round() == rate * 10 ? 1 : 2)}×';

String playbackTitle(MediaItem item) {
  if (item.type != 'Episode') return item.title;
  final series = item.data['SeriesName']?.toString().trim() ?? '';
  var episodeName = item.title.trim();
  final index = item.data['IndexNumber'];
  if (index != null) {
    // Only strip an ordinal that agrees with the structured episode identity.
    // Keep a genuine name (including any text following the ordinal).
    final ordinal = RegExp(
      r'^第\s*0*' + RegExp.escape('$index') + r'\s*集(?:\s*[·:：\-—]\s*|\s+|$)',
    ).firstMatch(episodeName);
    if (ordinal != null) {
      episodeName = episodeName.substring(ordinal.end).trim();
    }
  }
  return [
    if (series.isNotEmpty) series,
    if (item.data['ParentIndexNumber'] != null)
      '第 ${item.data['ParentIndexNumber']} 季',
    if (item.data['IndexNumber'] != null) '第 ${item.data['IndexNumber']} 集',
    if (episodeName.isNotEmpty) episodeName,
  ].join(' · ');
}

class PlayerChrome extends StatelessWidget {
  const PlayerChrome({
    super.key,
    required this.title,
    required this.visible,
    required this.ready,
    required this.playing,
    required this.position,
    required this.duration,
    required this.onBack,
    required this.onToggle,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onMenu,
    required this.onScrubStart,
    required this.onScrub,
    required this.onScrubEnd,
    this.warning,
    this.accountLabel,
    this.onPrevious,
    this.onNext,
    this.onInfo,
    this.onAudio,
    this.onSubtitles,
    this.onEpisodes,
    this.onRate,
    this.onQuality,
    this.onFit,
    this.filled = false,
    this.episode = false,
    this.speed = 1,
    this.menuAnchors = const {},
    this.status,
    this.locked = false,
    this.unlockVisible = false,
    this.onLock,
  });
  final VoidCallback? onPrevious, onNext, onInfo, onAudio, onSubtitles, onRate;
  final VoidCallback? onEpisodes, onQuality, onFit, onLock;
  final bool filled, episode, locked, unlockVisible;
  final double speed;
  final Map<String, GlobalKey> menuAnchors;
  final PlayerStatusData? status;
  final String title;
  final bool visible, ready, playing;
  final Duration position, duration;
  final VoidCallback? onBack;
  final VoidCallback onToggle, onSeekBack, onSeekForward, onMenu, onScrubStart;
  final ValueChanged<double> onScrub, onScrubEnd;
  final String? warning, accountLabel;
  Widget anchored(String name, Widget child) =>
      KeyedSubtree(key: menuAnchors[name], child: child);

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final compact = !wideLayout(context);
    final slider = SliderTheme(
      data: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: accentColor(context),
        inactiveTrackColor: const Color(0xFF51535C),
        thumbColor: Colors.white,
        overlayColor: accentColor(context).withValues(alpha: .16),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        trackShape: const PlaybackTimelineTrack(),
        trackGap: 0,
        padding: EdgeInsets.zero,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      child: Slider(
        key: const Key('playback-timeline'),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        value: position.inMilliseconds
            .clamp(0, duration.inMilliseconds)
            .toDouble(),
        max: duration.inMilliseconds > 0
            ? duration.inMilliseconds.toDouble()
            : 1,
        onChangeStart: (_) => onScrubStart(),
        onChanged: duration > Duration.zero ? onScrub : null,
        onChangeEnd: onScrubEnd,
      ),
    );
    Widget time(Duration value) => Text(
      clockText(value),
      style: TextStyle(
        color: Colors.white,
        fontSize: compact ? 11 : 13,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final transport = Row(
      key: const Key('player-transport-group'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (episode)
          playerButton(
            CupertinoIcons.backward_end_fill,
            '上一集',
            onPrevious,
            size: 23,
          ),
        playerButton(
          CupertinoIcons.gobackward_10,
          '快退 10 秒',
          onSeekBack,
          size: 30,
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 12),
          child: playerButton(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            playing ? '暂停' : '播放',
            onToggle,
            size: 42,
          ),
        ),
        playerButton(
          CupertinoIcons.goforward_10,
          '快进 10 秒',
          onSeekForward,
          size: 30,
        ),
        if (episode)
          playerButton(
            CupertinoIcons.forward_end_fill,
            '下一集',
            onNext,
            size: 23,
          ),
      ],
    );
    final rate = onRate == null
        ? const SizedBox(width: 52, height: 44)
        : anchored(
            'rate',
            Tooltip(
              message: '播放速度',
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(52, 44),
                onPressed: onRate,
                child: Text(
                  playbackRateText(speed),
                  style: TextStyle(color: accentColor(context), fontSize: 15),
                ),
              ),
            ),
          );
    final tools = Row(
      key: const Key('player-tools-group'),
      mainAxisSize: MainAxisSize.min,
      children: [
        rate,
        anchored(
          'audio',
          playerButton(CupertinoIcons.waveform, '音频', onAudio, size: 25),
        ),
        anchored(
          'subtitles',
          playerButton(Icons.subtitles_outlined, '字幕', onSubtitles, size: 25),
        ),
        if (episode && onEpisodes != null)
          anchored(
            'episodes',
            playerButton(
              CupertinoIcons.list_bullet,
              '选集',
              onEpisodes,
              size: 25,
            ),
          ),
        anchored(
          'root',
          playerButton(Icons.more_horiz, '播放器菜单', onMenu, size: 26),
        ),
      ],
    );
    final lockVisible = visible || (locked && unlockVisible);
    return Stack(
      children: [
        IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xD9000000),
                          Color(0x68000000),
                          Colors.transparent,
                        ],
                        stops: [0, .48, 1],
                      ),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      16 + safe.left,
                      10 + safe.top,
                      16 + safe.right,
                      24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (status != null) PlayerStatusBar(data: status!),
                        Row(
                          children: [
                            playerButton(
                              CupertinoIcons.chevron_back,
                              '退出播放',
                              onBack,
                              size: 24,
                            ),
                            anchored(
                              'info',
                              playerButton(
                                CupertinoIcons.exclamationmark_circle,
                                '影片与播放信息',
                                onInfo,
                                size: 24,
                                color: accentColor(context),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: phoneValue(context, 14, 16),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (accountLabel != null)
                                    Text(
                                      accountLabel!,
                                      key: const Key('player-account-label'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white60,
                                        fontSize: 10,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (ready && onFit != null)
                  Positioned(
                    left: 16 + safe.left,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: anchored(
                        'fit',
                        playerButton(
                          filled
                              ? CupertinoIcons.arrow_down_right_arrow_up_left
                              : CupertinoIcons.arrow_up_left_arrow_down_right,
                          '画面比例',
                          onFit,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                if (ready)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Color(0x75000000),
                            Color(0xE6000000),
                          ],
                          stops: [0, .42, 1],
                        ),
                      ),
                      padding: EdgeInsets.fromLTRB(
                        16 + safe.left,
                        20,
                        16 + safe.right,
                        8 + safe.bottom,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (warning != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                warning!,
                                style: const TextStyle(
                                  color: Colors.orange,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          Row(
                            children: [
                              time(position),
                              Expanded(
                                child: SizedBox(height: 36, child: slider),
                              ),
                              time(duration),
                            ],
                          ),
                          LayoutBuilder(
                            builder: (context, bounds) {
                              // Keep 44 dp targets. A narrow phone gets a second row.
                              final ratePainter = TextPainter(
                                text: TextSpan(
                                  text: playbackRateText(speed),
                                  style: DefaultTextStyle.of(
                                    context,
                                  ).style.copyWith(fontSize: 15),
                                ),
                                textDirection: Directionality.of(context),
                                textScaler: MediaQuery.textScalerOf(context),
                              )..layout();
                              final rateWidth = (ratePainter.width + 16).clamp(
                                52.0,
                                double.infinity,
                              );
                              ratePainter.dispose();
                              final toolsWidth =
                                  rateWidth +
                                  (3 +
                                          (episode && onEpisodes != null
                                              ? 1
                                              : 0)) *
                                      44;
                              final transportWidth =
                                  (episode ? 5 : 3) * 44 + (compact ? 8 : 24);
                              final needed =
                                  transportWidth + 2 * toolsWidth + 16;
                              if (bounds.maxWidth < needed) {
                                return Column(
                                  children: [
                                    transport,
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [tools],
                                    ),
                                  ],
                                );
                              }
                              return SizedBox(
                                height: 52,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    transport,
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: tools,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (onLock != null)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.only(right: 16 + safe.right),
              child: IgnorePointer(
                ignoring: !lockVisible,
                child: AnimatedOpacity(
                  opacity: lockVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: KeyedSubtree(
                    key: const Key('player-screen-lock'),
                    child: playerButton(
                      locked ? Icons.lock_outline : Icons.lock_open_outlined,
                      locked ? '解锁屏幕' : '锁定屏幕',
                      onLock,
                      size: 26,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Equal thickness on both sides of the handle, without a gap or endpoint dot.
class PlaybackTimelineTrack extends RoundedRectSliderTrackShape {
  const PlaybackTimelineTrack();
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) => super.paint(
    context,
    offset,
    parentBox: parentBox,
    sliderTheme: sliderTheme,
    enableAnimation: enableAnimation,
    textDirection: textDirection,
    thumbCenter: thumbCenter,
    secondaryOffset: secondaryOffset,
    isDiscrete: isDiscrete,
    isEnabled: isEnabled,
    additionalActiveTrackHeight: 0,
  );
}

Widget playerTextButton(String label, VoidCallback? onPressed) => Tooltip(
  message: label,
  child: CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    minimumSize: const Size(56, 44),
    onPressed: onPressed,
    child: Text(
      label,
      style: TextStyle(
        fontSize: 14,
        color: onPressed == null ? Colors.white30 : Colors.white,
      ),
    ),
  ),
);

Widget playerButton(
  IconData icon,
  String label,
  VoidCallback? onPressed, {
  double size = 28,
  Color? color,
}) => Builder(
  builder: (context) => Tooltip(
    message: label,
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(44, 44),
      onPressed: onPressed,
      child: Icon(
        icon,
        size: size,
        color: onPressed == null
            ? accentColor(context).withValues(alpha: .32)
            : color ?? accentColor(context),
        shadows: const [
          Shadow(color: Colors.black45, blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
    ),
  ),
);
