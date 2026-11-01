import 'package:flutter/cupertino.dart';
import '../core/models.dart';
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

String mediaVersionFacts(Json source) {
  final video =
      objects(
        source['MediaStreams'],
      ).where((stream) => stream['Type'] == 'Video').firstOrNull ??
      <String, dynamic>{};
  final width = integer(video['Width']), height = integer(video['Height']);
  final resolution = width >= 7600 || height >= 4200
      ? '8K'
      : width >= 3800 || height >= 2100
      ? '4K'
      : width >= 2500 || height >= 1400
      ? '1440p'
      : width >= 1900 || height >= 1000
      ? '1080p'
      : height > 0
      ? '${height}p'
      : '';
  final range = (video['VideoRangeType'] ?? video['VideoRange'] ?? '')
      .toString();
  final normalized = range.toLowerCase();
  final dolby =
      integer(video['DvProfile']) > 0 ||
      integer(video['DolbyVisionProfile']) > 0 ||
      normalized.contains('dovi') ||
      normalized.contains('dolby') ||
      normalized == 'dv';
  final size = integer(source['Size']);
  return [
    resolution,
    if (width > 0 && height > 0) '$width×$height',
    if (dolby) '杜比视界' else if (range.isNotEmpty) range.toUpperCase(),
    if (size > 0) '${(size / 1000000000).toStringAsFixed(2)} GB',
    if (video['Codec'] != null) '${video['Codec']}'.toUpperCase(),
  ].where((value) => value.isNotEmpty).join(' · ');
}

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
    Widget card(Json source, double width) {
      final id = source['Id'].toString();
      final active = id == chosen;
      final name = source['Name']?.toString().trim() ?? '';
      final facts = mediaVersionFacts(source);
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
              constraints: const BoxConstraints(minHeight: 96),
              padding: const EdgeInsets.all(12),
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
                    size: 22,
                    color: active
                        ? accentColor(context)
                        : secondaryColor(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          name.isEmpty ? '原文件版本' : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: labelColor(context),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          facts.isEmpty ? '版本信息未提供' : facts,
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
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '影片版本',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: labelColor(context),
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
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
                            (width * .86).clamp(160, 310).toDouble(),
                          ),
                        ),
                    ],
                  ),
                );
              }
              final columns = width >= 900
                  ? 3
                  : width >= 560
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
