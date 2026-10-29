import 'poster_actions.dart';
import 'poster_press.dart';
import 'package:flutter/cupertino.dart';
import '../core/emby.dart';
import '../core/models.dart';
import 'poster.dart';
import 'poster_art.dart';
import 'style.dart';
import 'resume_button.dart';
import 'episode_badge.dart';
import 'version_group.dart';
export 'browse_page.dart' show LibraryPage;

// NipaPlay's Emby catalogue uses HorizontalAnimeCard in both display surfaces.
// User's poster contract takes precedence: all covers are 2:3.
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.api,
    required this.onTap,
    this.onPlay,
    this.posterAction,
    this.active = true,
  });
  final MediaItem item;
  final EmbyClient api;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final Widget? posterAction;
  final bool active;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: PosterActionRegion(
        item: item,
        externalMenu: true,
        active: active,
        resume: posterAction != null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: mediaListPosterHeight(context) * posterAspectRatio,
              height: mediaListPosterHeight(context),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Poster(url: posterUrl(api, item), active: active),
                    EpisodeBadge(item: item),
                    VersionBadge(item: item),
                    if (onPlay != null)
                      ResumePlayButton(id: item.id, onPressed: onPlay!),
                    if (posterAction != null &&
                        PosterActionsScope.maybeOf(context) == null)
                      Positioned(bottom: 4, right: 0, child: posterAction!),
                  ],
                ),
              ),
            ),
            SizedBox(width: phoneValue(context, 12, 16)),
            Expanded(
              child: PosterPressFeedback(
                active: active,
                builder: (context, pressed, child) => DefaultTextStyle.merge(
                  key: Key(pressed ? 'media-text-pressed' : 'media-text-idle'),
                  style: TextStyle(
                    color: pressed ? null : labelColor(context),
                    // A foreground also covers the subtitle's explicit idle
                    // colour, keeping every line in the same press feedback.
                    foreground: pressed
                        ? (Paint()
                            ..color = Color.lerp(
                              groupedColor(context),
                              CupertinoColors.systemGrey,
                              .8,
                            )!)
                        : null,
                  ),
                  child: IconTheme.merge(
                    data: IconThemeData(
                      color: pressed
                          ? Color.lerp(
                              groupedColor(context),
                              CupertinoColors.systemGrey,
                              .8,
                            )
                          : null,
                    ),
                    child: child,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PosterActionTitle(
                      item: item,
                      active: active,
                      resume: posterAction != null,
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: phoneValue(context, 14, 16),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (item.resume > Duration.zero) ...[
                      Text(
                        '已看 ${item.resume.inMinutes} 分钟',
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Row(
                      children: [
                        if (item.rating.isNotEmpty) ...[
                          const Icon(CupertinoIcons.star_fill, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            item.rating,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        const Text('Emby', style: TextStyle(fontSize: 10)),
                      ],
                    ),
                    SizedBox(height: phoneValue(context, 5, 8)),
                    Expanded(
                      child: Text(
                        item.overview.isNotEmpty
                            ? item.overview
                            : item.subtitle,
                        maxLines: item.resume > Duration.zero ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: phoneValue(context, 12, 13),
                          height: 1.4,
                          color: secondaryColor(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
