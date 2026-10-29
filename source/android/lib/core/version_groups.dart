import 'accounts.dart';
import 'catalog.dart';
import 'image_identity.dart';
import 'models.dart';

/// Presentation projection only. Each member keeps its original item ID and
/// user data. An account owner travels with the group to reject stale actions.
class VersionGroup extends MediaItem {
  VersionGroup(this.owner, this.versions) : super(versions.first.data);
  final String owner;
  final List<MediaItem> versions;
}

// Use the same unambiguous type/TMDB validation as shared artwork. Conflicting
// provider fields cannot identify a work and must leave resources independent.
String? mediaIdentity(MediaItem item) => SharedImageIdentity.work(item);

CatalogView groupVersions(List<MediaItem> items, Session account) {
  final groups = <String, List<MediaItem>>{};
  for (final item in items) {
    final key = mediaIdentity(item) ?? 'item:${item.id}';
    final members = groups.putIfAbsent(key, () => []);
    if (!members.any((e) => e.id == item.id)) members.add(item);
  }
  final result = <MediaItem>[];
  final offsets = <String, int>{};
  for (final members in groups.values) {
    final item = members.length == 1
        ? members.first
        : VersionGroup(accountKey(account), List.unmodifiable(members));
    final letter = object(item.data[titleKeysField])['letter']?.toString();
    if (letter != null) offsets.putIfAbsent(letter, () => result.length);
    result.add(item);
  }
  return CatalogView(result, offsets);
}

String versionDescription(MediaItem item) {
  final sources = objects(item.data['MediaSources']);
  final streams = [
    ...objects(item.data['MediaStreams']),
    ...sources.expand((s) => objects(s['MediaStreams'])),
  ];
  final video = streams.where((s) => s['Type'] == 'Video').firstOrNull ?? {};
  final width = integer(video['Width']), height = integer(video['Height']);
  final resolution = width >= 3800 || height >= 2100
      ? '4K'
      : width >= 1900 || height >= 1000
      ? '1080p'
      : height > 0
      ? '${height}p'
      : '';
  final range =
      video['VideoRangeType']?.toString() ??
      video['VideoRange']?.toString() ??
      '';
  final dolby =
      range.toLowerCase().contains('dovi') ||
      range.toLowerCase().contains('dolby') ||
      integer(video['DolbyVisionProfile']) > 0;
  final rate = integer(video['BitRate']);
  final name = sources
      .map((s) => s['Name']?.toString() ?? '')
      .where((s) => s.isNotEmpty)
      .join(' / ');
  return [
    resolution,
    if (name.isNotEmpty && name != item.title) name,
    if (video['Codec'] != null) '${video['Codec']}'.toUpperCase(),
    if (dolby) '杜比视界' else if (range.isNotEmpty) range.toUpperCase(),
    if (rate > 0) '${(rate / 1000000).toStringAsFixed(1)} Mbps',
    if (item.year.isNotEmpty) item.year,
  ].where((s) => s.isNotEmpty).join(' · ');
}

String sourceDescription(Json source) {
  final label = versionDescription(
    MediaItem({
      'Name': '',
      'MediaSources': [source],
    }),
  );
  return label.isEmpty
      ? '${source['Name'] ?? source['Container'] ?? '原文件'}'
      : label;
}
