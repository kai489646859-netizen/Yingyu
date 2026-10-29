import 'poster_actions.dart';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;
import '../core/catalog_sort.dart';
import '../core/catalog_filters.dart' show releaseYear;
import '../core/emby.dart';
import '../core/interface_preferences.dart';
import '../core/models.dart';
import 'episode_badge.dart';
import 'poster.dart';
import 'poster_art.dart';
import 'style.dart';
import 'version_group.dart';

/// Both display styles use the same permanent side gutters. The alphabet rail
/// occupies the right gutter; hiding it never resizes or repositions a card.
class LibraryGridMetrics {
  LibraryGridMetrics(
    double width,
    double textScale,
    LibraryDisplay display, {
    bool phone = false,
  }) {
    inset = phone ? 16 : pageInset(width);
    rightInset = phone ? 28 : inset;
    spacing = width < 600 ? 12 : 20;
    final available = width - inset - rightInset;
    columns = display == LibraryDisplay.posters
        ? phone
              ? 3
              : math.max(3, ((available + spacing) / 160).round())
        : width < 600
        ? 1
        : width < 840
        ? 2
        : 3;
    final cardWidth = (available - spacing * (columns - 1)) / columns;
    rowHeight = display == LibraryDisplay.posters
        ? cardWidth / posterAspectRatio + (phone ? 22 : 24) + 36 * textScale
        : (phone ? 112 : 140) * textScale.clamp(1, 1.5);
  }
  late final double inset, rightInset, spacing, rowHeight;
  late final int columns;
}

/// Presentation only: the very same scoped item and artwork/cache identity are
/// passed through to the existing detail and playback flow.
class LibraryPosterCard extends StatelessWidget {
  const LibraryPosterCard({
    super.key,
    required this.item,
    required this.api,
    required this.onTap,
    required this.active,
  });
  final MediaItem item;
  final EmbyClient api;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      // Match the supplied Popcorn reference at its eight-column poster width.
      // Narrow three-column phone posters keep the same visual text proportion.
      final fontScale = (bounds.maxWidth / 134).clamp(12 / 14, 1.0);
      final year = releaseYear(item)?.toString() ?? '';
      final rating = catalogSortValue(item, 'CommunityRating');
      return Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: posterAspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    phoneLayout(context) ? 14 : 6,
                  ),
                  child: PosterActionRegion(
                    item: item,
                    externalMenu: true,
                    active: active,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Poster(url: posterUrl(api, item), active: active),
                        EpisodeBadge(item: item),
                        VersionBadge(item: item),
                        if (rating != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(6, 18, 6, 4),
                              alignment: Alignment.bottomRight,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Color(0xB3000000),
                                  ],
                                ),
                              ),
                              child: Text(
                                rating.toStringAsFixed(1),
                                maxLines: 1,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14 * fontScale,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              PosterActionTitle(
                item: item,
                active: active,
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14 * fontScale,
                    height: 1.3,
                    fontWeight: FontWeight.w400,
                    color: labelColor(context),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                year,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12 * fontScale,
                  height: 1.3,
                  color: secondaryColor(context),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
