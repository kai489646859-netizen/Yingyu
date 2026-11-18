import 'package:flutter/cupertino.dart';
import '../core/models.dart';
import '../core/video_labels.dart';
import 'style.dart';

List<Json> playableVersions(MediaItem item) {
  final seen = <String>{};
  return objects(item.data['MediaSources'])
      .where((source) {
        final id = source['Id']?.toString() ?? '';
        return id.trim().isNotEmpty && seen.add(id);
      })
      .toList(growable: false);
}

String mediaVersionFacts(Json source) => mediaSourceFacts(source);

class MediaVersions extends StatefulWidget {
  const MediaVersions({
    super.key,
    this.item,
    required this.sources,
    required this.selected,
    required this.onSelected,
    this.onInspect,
    this.onInspected,
    this.enabled = true,
  });
  final MediaItem? item;
  final List<Json> sources;
  final String? selected;
  final ValueChanged<String> onSelected;
  final Future<Json?> Function(String)? onInspect;
  final void Function(String, Json)? onInspected;
  final bool enabled;

  @override
  State<MediaVersions> createState() => _MediaVersionsState();
}

class _MediaVersionsState extends State<MediaVersions> {
  final inspected = <String, Json>{};
  String? pending;
  final notices = <String, String>{};

  Json videoFor(Json source) => resourceVideo(
    MediaItem({
      if (widget.sources.length == 1) ...?widget.item?.data,
      'MediaSources': [source],
    }),
  );

  Json displayed(Json source) {
    final extra = inspected[source['Id'].toString()];
    if (extra == null) return source;
    final original = videoFor(source), queried = videoFor(extra);
    return {
      ...source,
      if (integer(extra['Size']) > 0) 'Size': extra['Size'],
      if ('${extra['Container'] ?? ''}'.trim().isNotEmpty)
        'Container': extra['Container'],
      if (extra['Name'] is String && versionNameHints(extra).isNotEmpty)
        'Name': extra['Name'],
      versionHintsKey: {
        ...versionNameHints(source),
        ...versionNameHints(extra),
      },
      'MediaStreams': [
        {
          ...original,
          for (final entry in queried.entries)
            if (entry.key != versionHintsKey &&
                entry.value != null &&
                entry.value != '' &&
                (!const {'Width', 'Height'}.contains(entry.key) ||
                    integer(entry.value) > 0))
              entry.key: entry.value,
          'Type': 'Video',
        },
      ],
    };
  }

  Future<void> inspect(String id) async {
    if (pending != null) return;
    setState(() => pending = id);
    try {
      final source = await widget.onInspect!(id);
      if (!mounted) return;
      final original = widget.sources.where((s) => s['Id'] == id).firstOrNull;
      if (original == null) return;
      setState(() {
        if (source != null && source['Id'] == id) inspected[id] = source;
        final video = videoFor(displayed(original));
        notices[id] = videoResolutionLabel(video).isEmpty
            ? '服务器暂未提供完整分辨率，可在播放信息查看'
            : '已补查该版本的服务器资料';
      });
      if (source != null && source['Id'] == id) {
        widget.onInspected?.call(id, videoFor(displayed(original)));
      }
    } catch (_) {
      if (mounted) setState(() => notices[id] = '补查未完成，可以重试');
    } finally {
      if (mounted) setState(() => pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = widget.sources.map(displayed).toList();
    if (sources.isEmpty) return const SizedBox.shrink();
    final chosen = sources.any((s) => s['Id'].toString() == widget.selected)
        ? widget.selected!
        : sources.first['Id'].toString();
    final current = sources.firstWhere((s) => s['Id'].toString() == chosen);
    String shortName(Json source) {
      final video = videoFor(source);
      final labels = resourceLabels(video);
      if (labels.isNotEmpty) return labels.join(' ');
      final codec = resourceCodecLabel(video);
      return codec;
    }

    final currentFacts = shortName(current);
    final names = sources.map(shortName).toList();
    Widget card(Json source, double width) {
      final id = source['Id'].toString();
      final active = id == chosen;
      final name = shortName(source);
      final index = sources.indexOf(source);
      final video = videoFor(source);
      final size = integer(source['Size']);
      final codec = resourceCodecLabel(video);
      final container = '${source['Container'] ?? ''}'.split(',').first.trim();
      final facts = [
        if (codec.isNotEmpty && codec != name) codec,
        if (RegExp(r'^[a-zA-Z0-9]{1,12}$').hasMatch(container))
          container.toUpperCase(),
        if (size > 0) '${(size / 1000000000).toStringAsFixed(2)} GB',
      ].join(' · ');
      return SizedBox(
        width: width,
        child: Semantics(
          selected: active,
          child: CupertinoButton(
            key: ValueKey('media-version-$id'),
            padding: EdgeInsets.zero,
            onPressed: widget.enabled ? () => widget.onSelected(id) : null,
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: active
                    ? accentColor(context).withValues(alpha: .12)
                    : labelColor(context).withValues(alpha: .05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: active
                      ? accentColor(context)
                      : labelColor(context).withValues(alpha: .18),
                  width: active ? 1.5 : .5,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    active
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.film,
                    size: 18,
                    color: active
                        ? accentColor(context)
                        : secondaryColor(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          name.isEmpty
                              ? '版本 ${index + 1}'
                              : names.where((n) => n == name).length > 1
                              ? '$name · 版本${index + 1}'
                              : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: labelColor(context),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          facts.isEmpty ? '原文件' : facts,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: secondaryColor(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '资源版本',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: labelColor(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '当前选择：${currentFacts.isEmpty ? '版本 ${sources.indexOf(current) + 1}' : currentFacts}',
            key: const Key('selected-version-summary'),
            style: TextStyle(fontSize: 13, color: labelColor(context)),
          ),
          const SizedBox(height: 4),
          Text(
            sources.length > 1 ? '选择版本后播放' : '当前仅提供一个版本',
            style: TextStyle(fontSize: 12, color: secondaryColor(context)),
          ),
          if (widget.onInspect != null &&
              videoResolutionLabel(videoFor(current)).isEmpty)
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 6),
              onPressed: widget.enabled && pending == null
                  ? () => inspect(chosen)
                  : null,
              child: Text(pending == chosen ? '正在检测…' : '检测当前版本格式'),
            ),
          if (notices[chosen] case final String notice)
            Text(
              notice,
              style: TextStyle(fontSize: 12, color: secondaryColor(context)),
            ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final scale = (MediaQuery.textScalerOf(context).scale(13) / 13)
                  .clamp(1.0, 2.0);
              if (phoneLayout(context)) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final source in sources)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: card(
                            source,
                            (width * .65)
                                .clamp(150 * scale, 230 * scale)
                                .clamp(0.0, width)
                                .toDouble(),
                          ),
                        ),
                    ],
                  ),
                );
              }
              final columns = width >= 150 * scale * 3 + 20
                  ? 3
                  : width >= 150 * scale * 2 + 10
                  ? 2
                  : 1;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final source in sources)
                    card(source, (width - (columns - 1) * 10) / columns),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
