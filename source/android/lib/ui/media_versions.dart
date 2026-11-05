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

class MediaVersions extends StatelessWidget {
  const MediaVersions({
    super.key,
    required this.sources,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
  });
  final List<Json> sources;
  final String? selected;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();
    final chosen = sources.any((s) => s['Id'].toString() == selected)
        ? selected
        : sources.first['Id'].toString();
    final current = sources.firstWhere((s) => s['Id'].toString() == chosen);
    String shortName(Json source) => resourceName(
      resourceVideo(
        MediaItem({
          'MediaSources': [source],
        }),
      ),
    );
    final currentFacts = shortName(current);
    final names = sources.map(shortName).toList();
    Widget card(Json source, double width) {
      final id = source['Id'].toString();
      final active = id == chosen;
      final name = shortName(source);
      final index = sources.indexOf(source);
      final video = resourceVideo(
        MediaItem({
          'MediaSources': [source],
        }),
      );
      final size = integer(source['Size']);
      final facts = [
        if (video['Codec'] != null) '${video['Codec']}'.toUpperCase(),
        if (size > 0) '${(size / 1000000000).toStringAsFixed(2)} GB',
      ].join(' · ');
      return SizedBox(
        width: width,
        child: Semantics(
          selected: active,
          child: CupertinoButton(
            key: ValueKey('media-version-$id'),
            padding: EdgeInsets.zero,
            onPressed: enabled ? () => onSelected(id) : null,
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
                          names.where((n) => n == name).length > 1
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
                          maxLines: 1,
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
            '当前选择：$currentFacts',
            key: const Key('selected-version-summary'),
            style: TextStyle(fontSize: 13, color: labelColor(context)),
          ),
          const SizedBox(height: 4),
          Text(
            sources.length > 1 ? '选择版本后播放 · 格式为服务器标注' : '当前仅提供一个版本 · 格式为服务器标注',
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
