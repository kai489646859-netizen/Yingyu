import '../core/models.dart';

/// IDs belong to MPV, sourcePid belongs to the transport stream. Never use a
/// menu position or an Emby stream index as an MPV track ID.
class TrackOption {
  const TrackOption(
    this.id,
    this.label,
    this.value, {
    this.language = '',
    this.title = '',
    this.codec = '',
    this.sourcePid,
    this.ffIndex,
    this.channels,
    this.external = false,
    this.forced = false,
    this.isDefault = false,
    this.subtitleHint = '',
  });
  final String id, label, language, title, codec;
  final Object value;
  final int? sourcePid, ffIndex, channels;
  final bool external, forced, isDefault;
  final String subtitleHint;
  bool get control => id == 'auto' || id == 'no';
  bool get bitmap => const {
    'hdmv_pgs_subtitle',
    'pgs',
    'dvd_subtitle',
    'dvdsub',
    'dvb_subtitle',
    'xsub',
  }.contains(codec.toLowerCase());
  String get signature =>
      '$id|$language|$title|$codec|$sourcePid|$ffIndex|$channels|$external|$forced|$subtitleHint';
}

class ExternalSubtitle {
  const ExternalSubtitle(this.route);
  final PlaybackRoute route;
}

class LocalSubtitle {
  const LocalSubtitle(this.path);
  final String path;
}

String normalizedCodec(String codec) => switch (codec.toLowerCase()) {
  'hdmv_pgs_subtitle' => 'pgs',
  'subrip' => 'srt',
  'dvd_subtitle' => 'dvdsub',
  _ => codec.toLowerCase(),
};

/// Emby's index is global to MediaStreams, MPV's ID is per track type.
/// Never send the menu ordinal or a Blu-ray PID as an Emby index.
int? embyTrackIndex(TrackOption track, bool subtitles, List<Json> streams) {
  if (track.id == 'no') return subtitles ? -1 : null;
  if (track.control) return null;
  final candidates = streams
      .where(
        (s) =>
            s['Type'] == (subtitles ? 'Subtitle' : 'Audio') &&
            s['Index'] is num &&
            (s['IsExternal'] == true) == track.external,
      )
      .toList();
  if (track.external) {
    final index = int.tryParse(track.id.replaceFirst('external-', ''));
    return candidates.where((s) => integer(s['Index']) == index).length == 1
        ? index
        : null;
  }
  bool compatible(Json s) {
    final codec = '${s['Codec'] ?? ''}';
    final language = '${s['Language'] ?? ''}';
    return (codec.isEmpty ||
            track.codec.isEmpty ||
            normalizedCodec(codec) == normalizedCodec(track.codec)) &&
        (language.isEmpty ||
            track.language.isEmpty ||
            trackLanguageLabel(language) ==
                trackLanguageLabel(track.language)) &&
        (track.channels == null ||
            s['Channels'] == null ||
            integer(s['Channels']) == track.channels);
  }

  if (track.ffIndex != null) {
    final exact = candidates
        .where((s) => integer(s['Index']) == track.ffIndex && compatible(s))
        .toList();
    if (exact.length == 1) return integer(exact.single['Index']);
  }
  final pid = candidates
      .where(
        (s) =>
            track.sourcePid != null &&
            s['Pid'] is num &&
            integer(s['Pid']) == track.sourcePid &&
            compatible(s),
      )
      .toList();
  if (pid.length == 1) return integer(pid.single['Index']);
  if (trackLanguageLabel(track.language) == '语言未知' || track.codec.isEmpty) {
    return null;
  }
  final semantic = candidates
      .where(
        (s) =>
            compatible(s) &&
            '${s['Codec'] ?? ''}'.isNotEmpty &&
            '${s['Language'] ?? ''}'.isNotEmpty &&
            (track.title.isEmpty ||
                '${s['Title'] ?? ''}'.isEmpty ||
                normalizeTrackText(track.title) ==
                    normalizeTrackText('${s['Title']}')),
      )
      .toList();
  return semantic.length == 1 ? integer(semantic.single['Index']) : null;
}

TrackOption? embyTrackOption(
  int? index,
  bool subtitles,
  List<TrackOption> tracks,
  List<Json> streams,
) {
  if (index == null || index < -1) return null;
  if (index == -1 &&
      subtitles &&
      !streams.any((s) => s['Type'] == 'Subtitle')) {
    // Opaque STRM often reports -1 because Emby has no subtitle inventory.
    // That is not evidence that the user explicitly disabled MPV's PGS tracks.
    return null;
  }
  final matches = tracks
      .where((t) => embyTrackIndex(t, subtitles, streams) == index)
      .toList();
  return matches.length == 1 ? matches.single : null;
}

String normalizeTrackText(String text) => String.fromCharCodes(
  text.runes.map(
    (r) => r >= 0xff01 && r <= 0xff5e
        ? r - 0xfee0
        : r == 0x3000
        ? 32
        : r,
  ),
).trim().toUpperCase();

bool _token(String value, String expression) => RegExp(
  '(^|[^A-Z0-9])(?:$expression)'
  r'([^A-Z0-9]|$)',
).hasMatch(value);
bool _contains(String value, List<String> parts) => parts.any(value.contains);

/// PC 0.6.5 simplified-first ranking, independently expressed for Android.
/// PGS language alone proves Chinese, never simplified/traditional/bilingual.
int? subtitleRank(TrackOption track) {
  if (track.control) return null;
  final lang = normalizeTrackText(track.language).replaceAll('_', '-');
  final title = normalizeTrackText('${track.title} ${track.subtitleHint}');
  final tags = lang.split('-');
  final primary = tags.first;
  var chinese = const {
    'ZH',
    'ZHO',
    'CHI',
    'CMN',
    'YUE',
    'CHS',
    'CHT',
    'ZHS',
    'ZHT',
  }.contains(primary);
  final langSimple =
      const {'CHS', 'ZHS'}.contains(primary) ||
      chinese &&
          (tags.contains('HANS') ||
              !tags.contains('HANT') &&
                  (tags.contains('CN') || tags.contains('SG')));
  final langTrad =
      const {'CHT', 'ZHT'}.contains(primary) ||
      chinese &&
          (tags.contains('HANT') ||
              !tags.contains('HANS') &&
                  tags.any(const {'TW', 'HK', 'MO'}.contains));
  final titleSimple =
      _contains(title, [
        '简体',
        '簡體',
        '简中',
        '簡中',
        '简英',
        '簡英',
        '简日',
        '簡日',
        '简繁',
        '簡繁',
        '繁简',
        '繁簡',
      ]) ||
      _token(
        title,
        r'CHS|ZHS|SC|ZH[-_ ](?:HANS|CN|SG)(?:[-_ ]CN)?|SIMPLIFIED(?:[ -]?CHINESE)?',
      );
  final titleTrad =
      _contains(title, [
        '繁体',
        '繁體',
        '繁中',
        '繁英',
        '繁日',
        '繁简',
        '繁簡',
        '简繁',
        '簡繁',
      ]) ||
      _token(
        title,
        r'CHT|ZHT|TC|ZH[-_ ](?:HANT|TW|HK|MO)|TRADITIONAL(?:[ -]?CHINESE)?',
      );
  final simple = (langSimple || titleSimple) && !(langTrad || titleTrad);
  final traditional = (langTrad || titleTrad) && !(langSimple || titleSimple);
  chinese |=
      langSimple ||
      langTrad ||
      titleSimple ||
      titleTrad ||
      _contains(title, ['中文', '中字', '中英', '中日', '汉语', '漢語', '国语', '國語']) ||
      _token(title, r'CHINESE|MANDARIN|CHI|ZHO|CMN');
  final bilingual =
      _contains(title, [
        '双语',
        '雙語',
        '中英',
        '中日',
        '简英',
        '簡英',
        '简日',
        '簡日',
        '繁英',
        '繁日',
      ]) ||
      _token(
        title,
        r'BILINGUAL|DUAL[ -]SUB(?:TITLE)?S?|ENG|ENGLISH|JPN|JAPANESE',
      );
  final forced =
      track.forced ||
      _token(title, r'FORCED|SIGNS(?:[ &+]SONGS)?|SONGS') ||
      _contains(title, ['强制', '強制', '仅标牌', '僅標牌', '标牌字幕', '標牌字幕']);
  final int group;
  if (simple) {
    group = bilingual ? 1 : 0;
  } else if (chinese && !traditional) {
    group = bilingual ? 3 : 2;
  } else if (traditional) {
    group = bilingual ? 5 : 4;
  } else if (const {'ENG', 'EN'}.contains(primary) ||
      title.contains('英文') ||
      _token(title, 'ENGLISH')) {
    group = 6;
  } else {
    return null;
  }
  return group * 10 + (forced ? 1 : 0);
}

TrackOption? preferredSubtitle(List<TrackOption> tracks) {
  TrackOption? best;
  var score = 1000;
  for (final track in tracks) {
    final rank = subtitleRank(track);
    if (rank != null && rank < score) {
      best = track;
      score = rank;
    }
  }
  // Keep the established Chinese/English order. If none is identified, an
  // unlabelled real subtitle is better than switching subtitles off. Its
  // language label remains unknown; do not guess that it is Chinese.
  return best ??
      tracks
          .where((t) => !t.control && trackLanguageLabel(t.language) == '语言未知')
          .firstOrNull;
}

String trackLanguageLabel(String language) {
  final tag = language.trim().toLowerCase().replaceAll('_', '-');
  if (const {'chs', 'zhs', 'zh-cn', 'zh-sg'}.contains(tag) ||
      tag.contains('-hans')) {
    return '简中';
  }
  if (const {'cht', 'zht', 'zh-tw', 'zh-hk', 'zh-mo'}.contains(tag) ||
      tag.contains('-hant')) {
    return '繁中';
  }
  return switch (tag.split('-').first) {
    'zh' || 'chi' || 'zho' || 'cmn' => '中文',
    'yue' => '粤语',
    'en' || 'eng' => '英语',
    'ja' || 'jpn' => '日语',
    'ko' || 'kor' => '韩语',
    'fr' || 'fre' || 'fra' => '法语',
    'de' || 'ger' || 'deu' => '德语',
    'es' || 'spa' => '西班牙语',
    'it' || 'ita' => '意大利语',
    'ru' || 'rus' => '俄语',
    'pt' || 'por' => '葡萄牙语',
    'th' || 'tha' => '泰语',
    'vi' || 'vie' => '越南语',
    '' || 'und' || 'unknown' => '语言未知',
    _ => tag,
  };
}

/// Compact source labels use parsed codec/channel data; named Atmos remains a source label.
String compactAudioTrackLabel({
  required String language,
  required String codec,
  int? channels,
  String? channelLayout,
  String title = '',
}) {
  final layout = switch (channelLayout?.trim().toLowerCase()) {
    'mono' => '1.0',
    'stereo' => '2.0',
    final value => value ?? '',
  };
  final match = RegExp(
    r'^(\d+)\.(\d+)(?:\.(\d+))?(?:\([^()]*\))?$',
  ).firstMatch(layout);
  var channelText = channels != null && channels > 0 ? '$channels 声道' : '声道未知';
  if (match != null) {
    final parts = [match[1]!, match[2]!, if (match[3] != null) match[3]!];
    final count = parts.map(int.parse).fold(0, (a, b) => a + b);
    if (count > 0 && count <= 64 && (channels == null || channels == count)) {
      channelText = switch (parts.join('.')) {
        '1.0' => '单声道',
        '2.0' => '立体声',
        final value => '$value 环绕声',
      };
    }
  }
  final languageLabel = trackLanguageLabel(language);
  final name = title.replaceAll(RegExp(r'[\r\n\x00-\x1F]'), ' ').trim();
  // These describe the source track, never the device's output capability.
  final namedAtmos = RegExp(
    r'\batmos\b|全景声',
    caseSensitive: false,
  ).hasMatch(name);
  final format = namedAtmos
      ? '全景声'
      : switch (codec.toLowerCase()) {
          'truehd' => 'TrueHD',
          'eac3' => 'DD+',
          'ac3' => 'DD',
          _ => codec.toUpperCase(),
        };
  final purpose = <String>[
    if (RegExp(r'commentary|评论|評論|解说|解說', caseSensitive: false).hasMatch(name))
      '解说',
    if (RegExp(
      r'audio description|descriptive|视障|視障',
      caseSensitive: false,
    ).hasMatch(name))
      '视障口述',
  ];
  final languageName =
      RegExp(r'粤语|粵語|cantonese', caseSensitive: false).hasMatch(name)
      ? '粤语'
      : RegExp(r'国语|國語|普通话|普通話|mandarin', caseSensitive: false).hasMatch(name)
      ? '国语'
      : languageLabel;
  return [
    languageName,
    if (format.isNotEmpty) format,
    if (channelText != '声道未知') channelText.replaceAll(' 环绕声', ' 声道'),
    ...purpose,
  ].join(' · ');
}

String trackLabel({
  required String id,
  required String language,
  required String title,
  required String codec,
  int? channels,
  bool external = false,
  bool isDefault = false,
  bool forced = false,
  bool subtitles = false,
}) {
  if (!subtitles && !external && channels != null) {
    return compactAudioTrackLabel(
      language: language,
      codec: codec,
      channels: channels,
      title: title,
    );
  }
  final kind = switch (codec.toLowerCase()) {
    'hdmv_pgs_subtitle' => 'PGS',
    'subrip' => 'SRT',
    _ => codec.toUpperCase(),
  };
  var name = title
      .replaceAll(
        RegExp(r'HDMV Presentation Graph.*', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'[\r\n\x00-\x1F]'), ' ')
      .trim();
  final languageLabel = subtitleLanguageLabel(language, title);
  // Metadata supplements can repeat the same title in several fields.
  name = name.split(' · ').toSet().join(' · ');
  final redundant = {
    language.toLowerCase(),
    trackLanguageLabel(language).toLowerCase(),
    languageLabel.toLowerCase(),
    kind.toLowerCase(),
    if (languageLabel == '简中') ...['简体', '简体中文', '简中'],
    if (languageLabel == '繁中') ...['繁体', '繁体中文', '繁中'],
    if (const {'中文', '简中', '繁中'}.contains(languageLabel)) ...[
      '中文（简繁未标注）',
      'chinese',
      '汉语',
    ],
    if (languageLabel == '英语') ...['english', '英文'],
  };
  if (kind.isNotEmpty) {
    name = name.replaceAll(
      RegExp('[(（]${RegExp.escape(kind)}[)）]', caseSensitive: false),
      '',
    );
  }
  name = name
      .split(' · ')
      .map((part) => part.trim())
      .where(
        (part) => part.isNotEmpty && !redundant.contains(part.toLowerCase()),
      )
      .toSet()
      .join(' · ');
  final languageInName = RegExp(
    r'简体|簡體|繁体|繁體|简中|繁中|简英|繁英|中英|中文|英文|英语|汉语|国语|粵語|粤语',
    caseSensitive: false,
  ).hasMatch(name);
  final label = name.isEmpty
      ? languageLabel
      : languageInName
      ? name
      : '$languageLabel · $name';
  return [
    '$label${kind.isEmpty ? "" : "（$kind）"}',
    if (external) '外挂',
    if (forced && !RegExp('强制|強制|forced', caseSensitive: false).hasMatch(name))
      '强制',
  ].join(' · ');
}

String subtitleLanguageLabel(String language, String title) {
  final rank = subtitleRank(
    TrackOption('label', '', '', language: language, title: title),
  );
  return switch (rank == null ? null : rank ~/ 10) {
    0 || 1 => '简中',
    2 || 3 => '中文',
    4 || 5 => '繁中',
    _ => trackLanguageLabel(language),
  };
}

/// Supplement labels/ranking only after an unambiguous Emby stream match.
/// Keep native descriptors unchanged so existing manual preferences still match.
TrackOption subtitleMetadata(TrackOption track, List<Json> streams) {
  if (track.control) return track;
  final index = embyTrackIndex(track, true, streams);
  final candidates = streams
      .where(
        (s) =>
            s['Type'] == 'Subtitle' &&
            (s['IsExternal'] == true) == track.external,
      )
      .toList();
  var matches = candidates
      .where((s) => s['Index'] is num && integer(s['Index']) == index)
      .toList();
  if (matches.isEmpty && !track.external) {
    matches = candidates
        .where(
          (s) =>
              (track.sourcePid != null &&
                      s['Pid'] is num &&
                      integer(s['Pid']) == track.sourcePid ||
                  track.ffIndex != null &&
                      s['Index'] is num &&
                      integer(s['Index']) == track.ffIndex) &&
              (track.codec.isEmpty ||
                  '${s['Codec'] ?? ''}'.isEmpty ||
                  normalizedCodec(track.codec) ==
                      normalizedCodec('${s['Codec']}')),
        )
        .toList();
  }
  final source = matches.length == 1 ? matches.single : <String, dynamic>{};
  final script = trackLanguageLabel('${source['Language'] ?? ''}');
  final hints = <String>{
    if (track.subtitleHint.isNotEmpty) track.subtitleHint,
    if ('${source['Title'] ?? ''}'.isNotEmpty) '${source['Title']}',
    if ('${source['DisplayTitle'] ?? ''}'.isNotEmpty)
      '${source['DisplayTitle']}',
    if (script == '简中') '简体中文',
    if (script == '繁中') '繁体中文',
  };
  final hint = hints.join(' · ');
  final title = {if (track.title.isNotEmpty) track.title, ...hints}.join(' · ');
  return TrackOption(
    track.id,
    trackLabel(
      id: track.id,
      language: track.language,
      title: title,
      codec: track.codec,
      external: track.external,
      forced: track.forced,
      isDefault: track.isDefault,
      subtitles: true,
    ),
    track.value,
    language: track.language,
    title: track.title,
    codec: track.codec,
    sourcePid: track.sourcePid,
    ffIndex: track.ffIndex,
    channels: track.channels,
    external: track.external,
    forced: track.forced,
    isDefault: track.isDefault,
    subtitleHint: hint,
  );
}

String resolvedTrackLanguage(
  String language,
  int? sourcePid,
  Map<int, String>? discLanguages, {
  bool external = false,
}) {
  if (external ||
      !const {'', 'und', 'unknown'}.contains(language.trim().toLowerCase())) {
    return language;
  }
  return discLanguages?[sourcePid] ?? language;
}

Map<int, String> discTrackLanguages(dynamic rows) {
  if (rows is! List || rows.length > 131072) return const {};
  final found = <int, String>{}, conflicts = <int>{};
  for (final row in rows) {
    final value = object(row);
    final pid = integer(value['pid']);
    final language = value['language']?.toString().toLowerCase() ?? '';
    if (pid <= 0 ||
        pid > 8191 ||
        !RegExp(r'^[a-z]{3}$').hasMatch(language) ||
        language == 'und') {
      continue;
    }
    if (found.containsKey(pid) && found[pid] != language) conflicts.add(pid);
    found[pid] = language;
  }
  for (final pid in conflicts) {
    found.remove(pid);
  }
  return Map.unmodifiable(found);
}

/// Only non-secret descriptors are stored. IDs alone are never reused after a
/// restart; both ID/PID and metadata must match, or an unambiguous semantic match.
class TrackChoice {
  TrackChoice(this.data);
  factory TrackChoice.fromTrack(TrackOption t) => TrackChoice({
    'id': t.id,
    'language': t.language,
    'title': t.title,
    'codec': t.codec,
    'pid': t.sourcePid,
    'channels': t.channels,
    'external': t.external,
  });
  final Json data;
  bool get disabled => data['id'] == 'no';
  TrackOption? resolve(List<TrackOption> tracks, {bool sameItem = true}) {
    if (disabled) return tracks.where((t) => t.id == 'no').firstOrNull;
    final matches = tracks
        .where(
          (t) =>
              !t.control &&
              trackLanguageLabel(t.language) ==
                  trackLanguageLabel('${data['language'] ?? ''}') &&
              normalizeTrackText(t.title) ==
                  normalizeTrackText('${data['title'] ?? ''}') &&
              normalizedCodec(t.codec) ==
                  normalizedCodec('${data['codec'] ?? ''}') &&
              (data['channels'] == null ||
                  t.channels == null ||
                  data['channels'] == t.channels) &&
              t.external == data['external'],
        )
        .toList();
    if (sameItem) {
      final exact = matches
          .where(
            (t) =>
                t.id == data['id'] &&
                (data['pid'] == null || t.sourcePid == data['pid']),
          )
          .firstOrNull;
      if (exact != null) return exact;
      final pid = matches
          .where((t) => data['pid'] != null && t.sourcePid == data['pid'])
          .toList();
      if (pid.length == 1) return pid.single;
    }
    final known =
        trackLanguageLabel('${data['language'] ?? ''}') != '语言未知' ||
        '${data['title'] ?? ''}'.trim().isNotEmpty;
    return known && matches.length == 1 ? matches.single : null;
  }
}
