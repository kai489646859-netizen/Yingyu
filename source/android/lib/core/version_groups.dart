import 'accounts.dart';
import 'catalog.dart';
import 'image_identity.dart';
import 'models.dart';
import 'video_labels.dart';

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
  // A source describes one file. Do not combine dimensions from a different
  // top-level or second-source stream with the first file's name.
  final source = sources.firstOrNull;
  final streams = objects(source?['MediaStreams']);
  final video =
      (streams.isNotEmpty
              ? streams
              : sources.length <= 1
              ? objects(item.data['MediaStreams'])
              : <Json>[])
          .where((s) => s['Type'] == 'Video')
          .firstOrNull ??
      {};
  final resolution = videoResolutionLabel(video);
  final range = videoRangeLabel(video);
  final rate = integer(video['BitRate']);
  final name = sources
      .map((s) => s['Name']?.toString() ?? '')
      .where((s) => s.isNotEmpty)
      .join(' / ');
  return [
    resolution,
    if (name.isNotEmpty && name != item.title) name,
    if (video['Codec'] != null) '${video['Codec']}'.toUpperCase(),
    range,
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
