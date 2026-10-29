import 'package:flutter/cupertino.dart';
import '../core/models.dart';
import '../core/subtitle_document.dart';
import '../ui/style.dart';
import '../ui/surface.dart';
import 'session.dart';
import 'subtitle_files.dart';

String? onlineSubtitleCodec(Json candidate) =>
    switch (candidate['Format']?.toString().toLowerCase().trim()) {
      'srt' || 'subrip' => 'srt',
      'ass' => 'ass',
      'ssa' => 'ssa',
      'vtt' || 'webvtt' => 'vtt',
      _ => null,
    };

class SubtitleSearch extends StatefulWidget {
  const SubtitleSearch({super.key, required this.session});
  final PlaybackSession session;
  @override
  State<SubtitleSearch> createState() => _SubtitleSearchState();
}

class _SubtitleSearchState extends State<SubtitleSearch> {
  String language = 'chi';
  List<Json> results = [];
  bool busy = false, searched = false;
  String? error, selectedId;
  int revision = 0;
  SubtitleFiles? downloading;
  late final PlaybackSession owner;
  late final PlaybackRoute? route;
  late final Session account;

  @override
  void initState() {
    super.initState();
    owner = widget.session;
    route = owner.route;
    account = owner.account;
  }

  bool valid(int r) =>
      mounted &&
      revision == r &&
      identical(widget.session, owner) &&
      !owner.closed &&
      identical(owner.route, route) &&
      owner.api.session == account;

  Future<void> search() async {
    if (busy || !valid(revision)) return;
    final r = ++revision;
    setState(() {
      busy = true;
      error = null;
      searched = true;
      results = [];
    });
    try {
      final source = route?.sourceId;
      if (source == null || source.isEmpty) {
        throw const AppFailure('当前影片尚未准备好，请开始播放后重试');
      }
      final value = await owner.api.searchSubtitles(
        owner.item.id,
        language,
        source,
      );
      if (valid(r)) setState(() => results = value);
    } catch (e) {
      if (valid(r)) {
        setState(() => error = '字幕搜索失败：${safeError(e)}。请确认服务器已配置字幕源及账号权限。');
      }
    } finally {
      if (valid(r)) setState(() => busy = false);
    }
  }

  Future<void> use(Json candidate) async {
    final id = candidate['Id']?.toString() ?? '';
    final codec = onlineSubtitleCodec(candidate);
    if (id.isEmpty || codec == null || busy || !valid(revision)) return;
    final r = ++revision;
    setState(() {
      busy = true;
      selectedId = id;
      error = null;
    });
    SubtitleFiles? files;
    try {
      files = SubtitleFiles(maxBytes: 8 * 1024 * 1024);
      downloading = files;
      final file = await files.load(
        'selected',
        owner.api.remoteSubtitleRoute(id),
        codec,
      );
      if (!valid(r)) return;
      final document = SubtitleDocument(
        file.path,
        '${candidate['Name'] ?? '在线字幕'}',
        codec,
        files.close,
        language:
            '${candidate['Language'] ?? candidate['ThreeLetterISOLanguageName'] ?? language}',
      );
      downloading = null;
      files = null; // attachSubtitle takes ownership, including error cleanup.
      await owner.attachSubtitle(document);
      if (mounted && valid(r)) Navigator.pop(context);
    } catch (e) {
      if (valid(r)) {
        setState(() => error = '字幕下载或应用失败：${safeError(e)}。可重试或选择其他字幕。');
      }
    } finally {
      downloading = null;
      await files?.close();
      if (valid(r)) {
        setState(() {
          busy = false;
          selectedId = null;
        });
      }
    }
  }

  @override
  void dispose() {
    revision++;
    downloading?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SurfacePage(
    title: '在线字幕搜索',
    playerMenu: true,
    compactPlayerMenu: true,
    playerMenuWidth: 380,
    child: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        const SettingsRow(
          '搜索当前影片的字幕',
          subtitle: '通过当前 Emby 服务器配置的字幕源搜索；下载仅用于本次播放。',
          showDisclosure: false,
        ),
        CupertinoSlidingSegmentedControl<String>(
          groupValue: language,
          children: const {
            'chi': Text('中文'),
            'eng': Text('英文'),
            'jpn': Text('日文'),
          },
          onValueChanged: (v) {
            if (!busy && v != null) {
              setState(() {
                language = v;
                results = [];
                searched = false;
                error = null;
              });
            }
          },
        ),
        CupertinoButton(
          key: const Key('online-subtitle-search'),
          onPressed: busy ? null : search,
          child: Text(searched ? '重新搜索' : '搜索字幕'),
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.all(8),
            child: CupertinoActivityIndicator(),
          ),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        if (searched && !busy && results.isEmpty && error == null)
          const SettingsRow(
            '没有找到字幕',
            subtitle: '可切换语言重试；也请确认服务器已配置字幕源。',
            showDisclosure: false,
          ),
        for (final value in results)
          SettingsRow(
            '${value['Name'] ?? '字幕'}',
            key: ValueKey('online-subtitle:${value['Id']}'),
            subtitle: [
              '${value['ProviderName'] ?? '字幕源'}',
              '${value['Language'] ?? value['ThreeLetterISOLanguageName'] ?? language}',
              '${value['Format'] ?? '未知格式'}',
              if (value['IsHashMatch'] == true) '文件匹配',
              if (value['IsForced'] == true) '强制字幕',
              if (value['IsHearingImpaired'] == true) '听障字幕',
              if (onlineSubtitleCodec(value) == null) '暂不支持此格式',
            ].join(' · '),
            trailing: Text(selectedId == value['Id'] ? '正在下载' : '下载并使用'),
            showDisclosure: false,
            onTap:
                busy ||
                    onlineSubtitleCodec(value) == null ||
                    '${value['Id'] ?? ''}'.isEmpty
                ? null
                : () => use(value),
          ),
      ],
    ),
  );
}
