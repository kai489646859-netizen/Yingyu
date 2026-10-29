import 'poster_actions.dart';
import 'home_visibility.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../core/home_feed.dart';
import '../core/models.dart';
import 'poster.dart';
import 'poster_art.dart';
import 'style.dart';
import 'resume_button.dart';
import 'poster_motion.dart';
import 'swipe_pages.dart';
import 'resume_menu.dart';
import 'watch_progress.dart';
import '../core/appearance.dart';

String continueWatchingCaption(MediaItem item, {WatchProgressState? progress}) {
  final completed =
      progress?.completed ??
      (object(item.data['UserData'])['Played'] == true &&
          item.resume == Duration.zero);
  final episode = item.type == 'Episode'
      ? '第 ${item.data['ParentIndexNumber'] ?? '?'} 季 · 第 ${item.data['IndexNumber'] ?? '?'} 集'
      : '';
  if (completed) {
    return episode.isEmpty
        ? '已看完'
        : '已看完 · ${item.data['ParentIndexNumber'] ?? '?'}季${item.data['IndexNumber'] ?? '?'}集';
  }
  if (progress != null && object(item.data['UserData'])['Played'] == true) {
    return '${episode.isEmpty ? '' : '$episode · '}${progress.label}';
  }
  return '${episode.isEmpty ? '' : '$episode · '}已看 ${(progress?.position ?? item.resume).inMinutes} 分钟';
}

class ContinueWatching extends StatelessWidget {
  const ContinueWatching({
    super.key,
    required this.feed,
    required this.active,
    required this.onPlay,
    required this.onDetail,
    this.onViewAll,
    this.allowRetry = true,
    this.showError = true,
  });
  final HomeFeed feed;
  final bool active;
  final Future<void> Function(MediaItem) onPlay, onDetail;
  final VoidCallback? onViewAll;
  final bool allowRetry;
  final bool showError;
  String? artwork(MediaItem item) => resumeArtworkUrl(feed.api, item);
  @override
  Widget build(BuildContext context) {
    final items = HomeVisibilityScope.visible(
      context,
      feed.account,
      feed.resume,
    );
    final busy = feed.resumeLoading || feed.loading;
    final error = feed.resumeError;
    if (items.isEmpty && !busy && error == null) return const SizedBox.shrink();
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final posterWidth = resumeArtworkWidth(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            contentInset(context),
            phoneValue(context, 2, 8),
            contentInset(context),
            phoneValue(context, 4, 12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '继续观看',
                  style: TextStyle(
                    fontSize: phoneValue(context, 17, 20),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onViewAll != null)
                CupertinoButton(
                  key: const Key('resume-view-all'),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  onPressed: onViewAll,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('查看全部', style: TextStyle(fontSize: 13)),
                      SizedBox(width: 4),
                      Icon(CupertinoIcons.chevron_forward, size: 13),
                    ],
                  ),
                ),
              if (busy)
                const SizedBox(
                  width: 24,
                  child: CupertinoActivityIndicator(
                    key: Key('home-loading-indicator'),
                    radius: 7,
                  ),
                ),
            ],
          ),
        ),
        if (error != null && showError)
          Padding(
            padding: EdgeInsets.fromLTRB(
              contentInset(context),
              0,
              contentInset(context),
              12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '继续观看读取失败：$error',
                    style: TextStyle(
                      fontSize: 13,
                      color: secondaryColor(context),
                    ),
                  ),
                ),
                if (allowRetry)
                  CupertinoButton(
                    onPressed: () => feed.refreshResume(force: true),
                    child: const Text('重试'),
                  ),
              ],
            ),
          ),
        if (items.isEmpty && !busy && error == null)
          Padding(
            padding: EdgeInsets.fromLTRB(
              contentInset(context),
              4,
              contentInset(context),
              20,
            ),
            child: Text(
              '暂无未看完的影视',
              style: TextStyle(fontSize: 13, color: secondaryColor(context)),
            ),
          ),
        if (items.isNotEmpty)
          HorizontalPageSwipeBoundary(
            child: SizedBox(
              height:
                  posterWidth / resumeArtworkAspectRatio + 10 + 60 * textScale,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                scrollCacheExtent: ScrollCacheExtent.pixels(posterWidth),
                padding: EdgeInsets.symmetric(
                  horizontal: contentInset(context),
                ),
                itemCount: items.length,
                separatorBuilder: (_, _) =>
                    SizedBox(width: phoneValue(context, 12, 16)),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final progress = WatchProgressState.resolve(
                    item,
                    feed.account,
                    feed.store,
                  );
                  final seriesName = item.data['SeriesName']?.toString() ?? '';
                  return PosterEntrance(
                    key: ValueKey('resume-entrance-${item.id}'),
                    id: 'resume:${item.id}',
                    active: active,
                    axis: Axis.horizontal,
                    child: SizedBox(
                      width: posterWidth,
                      child: Semantics(
                        button: true,
                        label: '${item.title} 详情',
                        child: GestureDetector(
                          key: ValueKey('resume-${item.id}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onDetail(item),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  key: ValueKey('resume-artwork-${item.id}'),
                                  height:
                                      posterWidth / resumeArtworkAspectRatio,
                                  child: PosterActionRegion(
                                    item: item,
                                    externalMenu: true,
                                    active: active,
                                    resume: true,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Poster(
                                          url: artwork(item),
                                          kind: PosterKind.landscape,
                                          fit:
                                              (artwork(item)?.contains(
                                                    '/Images/Backdrop/',
                                                  ) ??
                                                  false)
                                              ? BoxFit.cover
                                              : BoxFit.contain,
                                          active: active,
                                        ),
                                        ResumePlayButton(
                                          id: item.id,
                                          onPressed: () => onPlay(item),
                                        ),
                                        if (PosterActionsScope.maybeOf(
                                              context,
                                            ) ==
                                            null)
                                          Positioned(
                                            bottom: 4,
                                            right: 0,
                                            child: ResumeMenu(
                                              feed: feed,
                                              item: item,
                                              onPoster: true,
                                            ),
                                          ),
                                        if (progress.known ||
                                            progress.completed)
                                          Positioned(
                                            left: 0,
                                            right: 0,
                                            bottom: 0,
                                            child: ColoredBox(
                                              color: const Color(0xCC101216),
                                              child: Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 1,
                                                ),
                                                child: LinearProgressIndicator(
                                                  key: ValueKey(
                                                    'resume-progress-${item.id}',
                                                  ),
                                                  value: progress.fraction,
                                                  minHeight: 4,
                                                  color:
                                                      (Theme.of(context)
                                                                  .extension<
                                                                    AccentTheme
                                                                  >()
                                                                  ?.choice ??
                                                              AppAccent.lilac)
                                                          .dark,
                                                  backgroundColor: const Color(
                                                    0xFF42454D,
                                                  ),
                                                  trackGap: 0,
                                                  stopIndicatorRadius: 0,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              PosterActionTitle(
                                item: item,
                                active: active,
                                resume: true,
                                child: Text(
                                  seriesName.isEmpty ? item.title : seriesName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: phoneValue(context, 13, 14),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                continueWatchingCaption(
                                  item,
                                  progress: progress,
                                ),
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
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
