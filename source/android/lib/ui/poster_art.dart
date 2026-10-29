import '../core/emby.dart';
import '../core/models.dart';

// Product contract: every poster wall uses 2:3. Keep 360px / quality 85.
const posterAspectRatio = 2 / 3;
const resumeArtworkAspectRatio = 16 / 9;

/// Use already returned artwork metadata. Never add a per-card detail query or
/// guess a missing backdrop. A portrait fallback is shown whole in the card.
String? resumeArtworkUrl(EmbyClient api, MediaItem item) {
  if (item.backdropTag.isNotEmpty) return api.imageUrl(item, backdrop: true);
  final owner = item.data['ParentBackdropItemId']?.toString() ?? '';
  final tags = item.data['ParentBackdropImageTags'];
  if (owner.isNotEmpty &&
      tags is List &&
      tags.isNotEmpty &&
      '${tags.first}'.isNotEmpty) {
    return api.imageUrl(
      MediaItem({
        'Id': owner,
        'Type': owner == item.data['SeriesId'] ? 'Series' : '',
        if (owner == item.data['SeriesId'])
          'ImageTags': {'Primary': item.data['SeriesPrimaryImageTag'] ?? ''},
        'BackdropImageTags': tags,
      }),
      backdrop: true,
    );
  }
  final thumb = object(item.data['ImageTags'])['Thumb']?.toString() ?? '';
  if (thumb.isNotEmpty) {
    return api.imageUrl(item, thumbnail: true);
  }
  final thumbOwner = item.data['ParentThumbItemId']?.toString() ?? '';
  final thumbTag = item.data['ParentThumbImageTag']?.toString() ?? '';
  if (thumbOwner.isNotEmpty && thumbTag.isNotEmpty) {
    return api.imageUrl(
      MediaItem({
        'Id': thumbOwner,
        'Type': thumbOwner == item.data['SeriesId'] ? 'Series' : '',
        'ImageTags': {
          'Thumb': thumbTag,
          if (thumbOwner == item.data['SeriesId'])
            'Primary': item.data['SeriesPrimaryImageTag'] ?? '',
        },
      }),
      thumbnail: true,
    );
  }
  return posterUrl(api, item);
}

/// Artwork ownership never changes the item's playback ID or progress.
/// Episodes share their series' Primary URL (and therefore the same cache file).
String? posterUrl(EmbyClient api, MediaItem item, {MediaItem? series}) {
  if (item.type == 'Episode' || item.type == 'Season') {
    final id =
        item.data['SeriesId']?.toString() ??
        (series?.series == true ? series!.id : '');
    if (id.isNotEmpty) {
      final ownTag = item.data['SeriesPrimaryImageTag']?.toString() ?? '';
      final tag = ownTag.isNotEmpty
          ? ownTag
          : (series?.id == id ? series!.imageTag : '');
      return api.imageUrl(
        MediaItem({
          'Id': id,
          'Type': 'Series',
          if (series?.id == id) 'ProviderIds': series!.data['ProviderIds'],
          'ImageTags': {'Primary': tag},
        }),
      );
    }
  }
  return item.imageTag.isEmpty ? null : api.imageUrl(item);
}
