import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/accounts.dart';
import '../ui/style.dart';
import '../ui/surface.dart';
import 'controls.dart';
import 'session.dart';
import 'tracks.dart';
import 'media_facts.dart';
import 'media_notice.dart';
import 'native_hdr.dart';

/// PC's circled-exclamation button invokes MPV's stats overlay. The mobile
/// surface presents only already available facts; opening it makes no request.
class PlaybackInfoPage extends StatefulWidget {
  const PlaybackInfoPage({super.key, required this.session});
  final PlaybackSession session;

  @override
  State<PlaybackInfoPage> createState() => _PlaybackInfoPageState();
}

class _PlaybackInfoPageState extends State<PlaybackInfoPage> {
  PlaybackSession get session => widget.session;
  final refresh = ValueNotifier<int>(0);
  Timer? timer;
  bool dirty = false, scrolling = false;
  String? lastError;
  late Object lastStructure;

  Object get structure => (
    session.selectedTrack(false),
    session.selectedTrack(true),
    session.ready,
    session.closed,
    session.seeking,
    session.error,
  );

  void changed() {
    dirty = true;
    final next = structure;
    if (next != lastStructure) {
      // Track and session transitions must invalidate stale facts at once.
      // Frequent clock/cache notifications share the deferred refresh below.
      lastStructure = next;
      dirty = false;
      lastError = session.error;
      refresh.value++;
    }
  }

  void pulse() {
    if (!dirty || (scrolling && session.error == lastError)) return;
    dirty = false;
    lastError = session.error;
    refresh.value++;
  }

  @override
  void initState() {
    super.initState();
    lastStructure = structure;
    session.addListener(changed);
    timer = Timer.periodic(const Duration(milliseconds: 500), (_) => pulse());
  }

  @override
  void didUpdateWidget(PlaybackInfoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != session) {
      oldWidget.session.removeListener(changed);
      session.addListener(changed);
      lastStructure = structure;
      dirty = true;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    session.removeListener(changed);
    refresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SurfacePage(
    title: '影片与播放信息',
    playerMenu: true,
    centered: true,
    playerMenuWidth: 560,
    child: NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event.depth == 0) {
          if (event is ScrollStartNotification) scrolling = true;
          if (event is ScrollEndNotification) scrolling = false;
        }
        return false;
      },
      child: RepaintBoundary(
        child: ListenableBuilder(
          listenable: refresh,
          builder: (context, _) {
            final backend = session.backend;
            final current =
                !session.closed &&
                    !session.seeking &&
                    backend is PlaybackFactsBackend
                ? (backend as PlaybackFactsBackend).mediaFacts
                : const PlaybackMediaFacts();
            final audioCurrent = current['aid'] == session.selectedTrack(false);
            final videos =
                session.route?.streams
                    .where((s) => s['Type'] == 'Video')
                    .toList() ??
                const [];
            final video = videos.length == 1 ? videos.single : null;
            final audioTrack = session
                .trackOptions(false)
                .where((t) => t.id == session.selectedTrack(false))
                .firstOrNull;
            final audioIndex = audioTrack == null
                ? null
                : embyTrackIndex(
                    audioTrack,
                    false,
                    session.route?.streams ?? [],
                  );
            final audios =
                session.route?.streams
                    .where(
                      (s) =>
                          s['Type'] == 'Audio' &&
                          audioIndex != null &&
                          integer(s['Index']) == audioIndex,
                    )
                    .toList() ??
                const [];
            final audio = audios.length == 1 ? audios.single : null;
            final serverRows = <Widget>[
              if ('${video?['Codec'] ?? ''}'.isNotEmpty)
                SettingsRow(
                  '视频编码（服务器标注）',
                  subtitle: safeError('${video!['Codec']}'),
                ),
              if (integer(video?['BitRate']) > 0)
                SettingsRow(
                  '视频码率（服务器标注）',
                  subtitle: mediaBitrate(video!['BitRate']),
                ),
              if (integer(video?['Width']) > 0 && integer(video?['Height']) > 0)
                SettingsRow(
                  '分辨率（服务器标注）',
                  subtitle: '${video!['Width']} × ${video['Height']}',
                ),
              if (integer(audio?['BitRate']) > 0)
                SettingsRow(
                  '音频码率（服务器标注）',
                  subtitle: mediaBitrate(audio!['BitRate']),
                ),
            ];
            String known(Object? value) =>
                value == null || '$value'.isEmpty ? '未提供' : safeError('$value');
            String bitrate(Object? value) => mediaBitrate(value);
            final resourceType = playbackResourceType(
              confirmedDisc: backend is PlaybackResourceBackend
                  ? (backend as PlaybackResourceBackend).discResourceType
                  : '',
              route: session.route,
              metadata: session.currentMetadata.data,
              format: current['file-format'],
              decoded: current.values,
              allowServerFormat:
                  current['vid']?.isNotEmpty == true &&
                  !const {'no', 'auto'}.contains(current['vid']),
            );

            String selected(bool subtitles) {
              final id = session.selectedTrack(subtitles);
              if (subtitles && id == 'no') return '关闭';
              return session
                      .trackOptions(subtitles)
                      .where((t) => t.id == id)
                      .firstOrNull
                      ?.label ??
                  '未提供';
            }

            return ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                SettingsGroup(
                  title: '当前账号',
                  children: [
                    SettingsRow(
                      accountName(session.account),
                      icon: CupertinoIcons.person_crop_circle,
                      subtitle: session.account.base.toString(),
                    ),
                  ],
                ),
                SettingsGroup(
                  title: '影片',
                  children: [
                    SettingsRow(
                      session.item.title,
                      icon: CupertinoIcons.film,
                      subtitle: session.item.subtitle,
                    ),
                    SettingsRow(
                      '资源类型',
                      subtitle: sourceFormatLabel(resourceType),
                    ),
                    if (resourceType.startsWith('封装格式未识别'))
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('当前播放未返回可识别的封装格式，视频编码和色彩信息仍单独显示。'),
                      ),
                    if (session.item.overview.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: SelectableText(session.item.overview),
                      ),
                    SettingsRow(
                      '播放进度',
                      subtitle:
                          '${clockText(session.position)} / ${clockText(backend.snapshot.duration)}',
                    ),
                  ],
                ),
                SettingsGroup(
                  title: '视频',
                  children: [
                    SettingsRow(
                      '当前视频编码',
                      subtitle: known(current['video-format']),
                    ),
                    SettingsRow(
                      '视频码率（当前估算）',
                      subtitle: bitrate(current['video-bitrate']),
                    ),
                    SettingsRow(
                      '当前视频尺寸',
                      subtitle:
                          integer(current['video-params/w']) > 0 &&
                              integer(current['video-params/h']) > 0
                          ? '${current['video-params/w']} × ${current['video-params/h']}'
                          : '未提供',
                    ),
                    SettingsRow(
                      '像素格式',
                      subtitle: known(current['video-params/pixelformat']),
                    ),
                    SettingsRow(
                      '色彩信息',
                      subtitle:
                          [
                                current['video-params/primaries'],
                                current['video-params/gamma'],
                                current['video-params/colorlevels'],
                              ]
                              .whereType<String>()
                              .where((s) => s.isNotEmpty)
                              .join(' · ')
                              .isEmpty
                          ? '未提供'
                          : [
                              current['video-params/primaries'],
                              current['video-params/gamma'],
                              current['video-params/colorlevels'],
                            ].whereType<String>().join(' · '),
                    ),
                    SettingsRow(
                      '片源帧率',
                      subtitle: known(current['container-fps']),
                    ),
                    if (backend is PlaybackOutputBackend) ...[
                      SettingsRow(
                        '当前显示',
                        subtitle: (backend as PlaybackOutputBackend)
                            .outputDescription,
                      ),
                      SettingsRow(
                        '当前屏幕能力',
                        subtitle: (backend as PlaybackOutputBackend)
                            .outputCapabilities
                            .displayDescription,
                      ),
                    ],
                    SettingsRow(
                      '当前硬件解码',
                      subtitle: known(current['hwdec-current']),
                    ),
                  ],
                ),
                SettingsGroup(
                  title: '音频与字幕',
                  children: [
                    if (backend is PlaybackOutputBackend) ...[
                      const SettingsRow(
                        '音频输出方式',
                        subtitle: '兼容 PCM 解码输出；未启用直通',
                      ),
                      SettingsRow(
                        '系统媒体路由',
                        subtitle: (backend as PlaybackOutputBackend)
                            .outputCapabilities
                            .audioDescription,
                      ),
                    ],
                    SettingsRow('当前音轨', subtitle: selected(false)),
                    SettingsRow(
                      '当前音频编码',
                      subtitle: known(
                        audioCurrent ? current['audio-codec-name'] : null,
                      ),
                    ),
                    SettingsRow(
                      '音频码率（当前估算）',
                      subtitle: bitrate(
                        audioCurrent ? current['audio-bitrate'] : null,
                      ),
                    ),
                    SettingsRow('当前字幕', subtitle: selected(true)),
                    SettingsRow(
                      '音频采样率',
                      subtitle:
                          !audioCurrent ||
                              integer(current['audio-params/samplerate']) <= 0
                          ? '未提供'
                          : '${current['audio-params/samplerate']} Hz',
                    ),
                    SettingsRow(
                      '解码音频声道',
                      subtitle: known(
                        audioCurrent ? current['audio-params/channels'] : null,
                      ),
                    ),
                    SettingsRow(
                      '设备输出声道',
                      subtitle: known(
                        audioCurrent
                            ? current['audio-out-params/channels']
                            : null,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        '当前码率由实际播放的数据包估算，会随片段变化，不受播放倍速影响。服务器标注单独显示；未能读取的信息不作猜测。',
                      ),
                    ),
                  ],
                ),
                if (serverRows.isNotEmpty)
                  SettingsGroup(title: '服务器补充资料', children: serverRows),
                SettingsGroup(
                  title: '播放状态',
                  children: [
                    SettingsRow(
                      '状态',
                      subtitle:
                          session.error ??
                          (session.loading
                              ? backend.snapshot.openingStage
                              : backend.snapshot.buffering
                              ? '正在缓冲'
                              : backend.snapshot.playing
                              ? '播放中'
                              : '已暂停'),
                    ),
                    SettingsRow('速度', subtitle: '${session.speed}×'),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

String playbackResourceType({
  required String confirmedDisc,
  required PlaybackRoute? route,
  required Json metadata,
  String? format,
  Map<String, String> decoded = const {},
  bool allowServerFormat = true,
}) {
  final container = _playbackContainerType(
    confirmedDisc: confirmedDisc,
    route: route,
    metadata: metadata,
    format: format,
  );
  final videoFormat = sourceVideoFormat(
    streams: route?.streams ?? const [],
    decoded: decoded,
    allowServerFallback: allowServerFormat,
  );
  return [container, if (videoFormat.isNotEmpty) videoFormat].join(' · ');
}

String _playbackContainerType({
  required String confirmedDisc,
  required PlaybackRoute? route,
  required Json metadata,
  String? format,
}) {
  if (confirmedDisc.isNotEmpty) return confirmedDisc;
  if (route?.discKind == DiscKind.iso) return 'ISO';
  if (route?.discKind == DiscKind.blurayFolder) return 'BDMV';
  final sources = objects(
    metadata['MediaSources'],
  ).where((s) => s['Id']?.toString() == route?.sourceId).toList();
  if (sources.length == 1) {
    final kind = discSourceKind(sources.single);
    if (kind == DiscKind.iso) return 'ISO';
    if (kind == DiscKind.blurayFolder) return 'BDMV';
  }
  // MPV has opened the actual stream, which may differ from the server's
  // wrapper (especially STRM). Preserve the outer disc identity above.
  final actual = _decodedContainerType(format);
  if (actual != null) return actual;
  if (sources.length == 1) {
    final container = sources.single['Container']?.toString().trim() ?? '';
    if (RegExp(r'^[a-zA-Z0-9]{1,16}$').hasMatch(container) &&
        container.toLowerCase() != 'strm') {
      return container.toUpperCase();
    }
  }
  return '封装格式未识别';
}

String? _decodedContainerType(String? format) {
  final name = format?.trim().toLowerCase() ?? '';
  if (name.isEmpty ||
      const {
        'edl',
        'lavf',
        'null',
        'unknown',
        'playlist',
        'strm',
      }.contains(name)) {
    return null;
  }
  // Format names are local codec identifiers, never paths or file names.
  // Keep safe unfamiliar identifiers visible instead of treating every format
  // outside the four original aliases as missing.
  if (!RegExp(
    r'^[a-z0-9][a-z0-9_+-]{0,31}(,[a-z0-9][a-z0-9_+-]{0,31}){0,7}$',
  ).hasMatch(name)) {
    return null;
  }
  return switch (name) {
    'matroska,webm' || 'matroska' => 'Matroska / WebM',
    'mov,mp4,m4a,3gp,3g2,mj2' || 'mov,mp4,m4a,3gp,3g2' || 'mov' => 'MP4 / MOV',
    'mpegts' => 'MPEG-TS',
    'mpeg' => 'MPEG-PS',
    'hls,applehttp' => 'HLS',
    'avi' => 'AVI',
    _ => name.split(',').map((value) => value.toUpperCase()).join(' / '),
  };
}
