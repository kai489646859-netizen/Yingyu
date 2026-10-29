import '../core/version_groups.dart';
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import '../core/emby.dart';
import '../core/background_work.dart';
import '../core/browse_cache.dart';
import '../core/models.dart';
import 'poster.dart';
import 'people.dart';
import '../core/episode_bands.dart';
import 'episode_band_picker.dart';
import 'poster_art.dart';
import 'style.dart';
import 'surface.dart';
import '../core/personal_library.dart';
import 'personal_library.dart';
import '../core/store.dart';
import 'offline_translation.dart';
import 'watch_progress.dart';
import '../core/personal_sync.dart';
import 'poster_actions.dart';

class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.item,
    required this.api,
    required this.play,
    this.browse,
    this.resumeEpisode,
    this.watchedEpisode,
    this.personal,
    this.store,
    this.personalSync,
  });
  final MediaItem item;
  final PersonalLibrary? personal;
  final PersonalSync? personalSync;
  final AppStore? store;
  final EmbyClient api;
  final BrowseRepository? browse;
  final MediaItem? resumeEpisode;
  final Future<MediaItem?> Function(String)? watchedEpisode;
  final Future<void> Function(MediaItem, String?, bool) play;
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> with WidgetsBindingObserver {
  late final personalAccount = widget.api.session;
  MediaItem? item;
  List<MediaItem> seasons = [], episodes = [];
  String? error, episodeError, seasonError, season, source;
  bool busy = true, episodeBusy = false;
  bool episodesPaused = false;
  bool metadataBusy = true;
  String? metadataError;
  int generation = 0, episodeRange = 0;
  int detailGeneration = 0;
  int focusRevision = 0;
  late MediaItem? focusEpisode = widget.resumeEpisode;
  String? historyError;
  bool historyLoaded = false;
  late bool focusResume = widget.resumeEpisode != null;
  final episodeScroll = ScrollController();
  final rangeScroll = ScrollController();
  static const rangeWidth = 112.0;
  List<MediaItem>? _bandSource;
  EpisodeBands? _bands;
  EpisodeBands get bands {
    if (!identical(_bandSource, episodes)) {
      _bandSource = episodes;
      _bands = EpisodeBands(episodes);
    }
    return _bands!;
  }

  int get rangeCount => bands.count;
  void jumpRange(int band) {
    final entries = bands.inBand(band);
    if (entries.isNotEmpty) {
      jumpEpisode(entries.first);
    } else {
      setState(() => episodeRange = band);
      revealRange();
    }
  }

  double get episodeHeight =>
      92 * (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 2);
  String? preferredSeason(List<MediaItem> values) {
    final target = focusEpisode;
    if (!focusResume || target == null) return null;
    return values
            .where((s) => s.id == target.data['SeasonId'])
            .firstOrNull
            ?.id ??
        values
            .where(
              (s) =>
                  s.data['IndexNumber'] != null &&
                  s.data['IndexNumber'] == target.data['ParentIndexNumber'],
            )
            .firstOrNull
            ?.id;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.store?.completions.addListener(progressChanged);
    episodeScroll.addListener(trackRange);
    item =
        widget.browse?.peek('detail:${widget.item.id}')?.items.firstOrNull ??
        (widget.item.series ? widget.item : null);
    seasons = widget.browse?.peek('seasons:${widget.item.id}')?.items ?? [];
    season =
        preferredSeason(seasons) ??
        focusEpisode?.data['SeasonId']?.toString() ??
        seasons.firstOrNull?.id;
    if (season != null) {
      final cached = widget.browse?.peek(
        BrowseRepository.episodeCatalogueKey(widget.item.id, season!),
      );
      episodes = List.of(cached?.items ?? []);
    }
    if (item?.series == true && season != null && focusEpisode != null) {
      unawaited(loadEpisodes(reset: true));
    }
    unawaited(load());
  }

  @override
  void dispose() {
    widget.store?.completions.removeListener(progressChanged);
    tabs.dispose();
    episodeScroll.dispose();
    rangeScroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void progressChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !busy &&
        !episodeBusy &&
        ModalRoute.of(context)?.isCurrent == true) {
      unawaited(load());
    }
  }

  Future<void> load({bool force = false}) async {
    final revision = ++detailGeneration;
    final focusIntent = focusRevision;
    final personalRevision = widget.personalSync?.revision;
    setState(() {
      busy = true;
      error = null;
      seasonError = null;
      episodesPaused = false;
      metadataBusy = true;
      metadataError = null;
    });
    try {
      // Keep the existing queue, but enqueue detail before optional panels so
      // slow seasons/history cannot delay the first cast/overview response.
      Future<(ItemPage?, Object?)> readSeasons() async {
        try {
          return (
            await (widget.browse?.seasons(widget.item.id) ??
                widget.api.seasons(widget.item.id)),
            null,
          );
        } catch (failure) {
          return (null, failure);
        }
      }

      final detailWork =
          widget.browse?.detail(widget.item.id, force: force) ??
          widget.api.detail(widget.item.id);
      final seasonWork = widget.item.series ? readSeasons() : null;
      Future<(MediaItem?, String?)> history() async {
        if (!widget.item.series) return (null, null);
        try {
          return (
            await (widget.watchedEpisode?.call(widget.item.id) ??
                    widget.api.lastWatchedEpisode(widget.item.id)) ??
                widget.resumeEpisode,
            null,
          );
        } on BackgroundPaused {
          return (focusEpisode, null);
        } catch (e) {
          return (focusEpisode, '观看记录读取失败：${safeError(e)}');
        }
      }

      String? earlyEpisodeSeason, earlyFocusId;
      final historyWork = history().then((result) {
        var (target, warning) = result;
        if (!mounted ||
            revision != detailGeneration ||
            widget.api.session != personalAccount) {
          return result;
        }
        if (widget.item.series &&
            widget.watchedEpisode == null &&
            widget.store != null &&
            personalAccount != null) {
          final local = widget.store!.completions.latest(
            personalAccount!,
            widget.item.id,
          );
          final remoteAt = DateTime.tryParse(
            '${object(target?.data['UserData'])['LastPlayedDate']}',
          );
          final localAt = DateTime.tryParse(
            '${object(local?.data['UserData'])['LastPlayedDate']}',
          );
          if (local != null &&
              localAt != null &&
              (remoteAt == null || localAt.isAfter(remoteAt))) {
            target = local;
          }
        }
        final move =
            target != null &&
            focusIntent == focusRevision &&
            (force ||
                target.id != focusEpisode?.id ||
                (!historyLoaded && focusResume));
        final previous = season;
        setState(() {
          historyLoaded = true;
          historyError = warning;
          focusEpisode = target;
          if (move) {
            focusResume = true;
            if (splitDetail) detailTab = 1;
            final targetSeason = target!.data['SeasonId']?.toString() ?? '';
            if (targetSeason.isNotEmpty) season = targetSeason;
          }
        });
        if (move) {
          earlyFocusId = target.id;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                splitDetail &&
                focusIntent == focusRevision &&
                tabs.hasClients) {
              tabs.jumpToPage(1);
            }
          });
          if (season != null &&
              (force ||
                  previous != season ||
                  (!episodeBusy && episodes.isEmpty))) {
            earlyEpisodeSeason = season;
            unawaited(loadEpisodes(reset: true, force: force));
          } else if (focusResume && episodes.isNotEmpty) {
            final at = episodes.indexWhere((e) => e.id == target!.id);
            if (at >= 0) {
              if (!episodeBusy) focusResume = false;
              jumpEpisode(at);
            }
          }
        }
        return (target, warning);
      });
      final detail = await detailWork;
      if (!mounted ||
          revision != detailGeneration ||
          widget.api.session != personalAccount) {
        return;
      }
      // Publish display metadata independently of season/history requests.
      // A failed optional panel must not hide a successfully read cast.
      setState(() {
        item = detail;
        metadataBusy = false;
      });
      final seasonResult = detail.series
          ? await (seasonWork ?? readSeasons())
          : (null, null);
      if (seasonResult.$2 is BackgroundPaused) {
        if (mounted && revision == detailGeneration) {
          setState(() => episodesPaused = true);
        }
        return;
      }
      final seasonFailure = seasonResult.$2;
      final values = seasonResult.$1?.items ?? seasons;
      if (!mounted ||
          revision != detailGeneration ||
          widget.api.session != personalAccount) {
        return;
      }
      final sync = widget.personalSync;
      if (sync != null && sync.current && sync.revision == personalRevision) {
        sync.observed[detail.id] = detail;
      }
      var (target, warning) = await historyWork;
      if (!mounted ||
          revision != detailGeneration ||
          widget.api.session != personalAccount) {
        return;
      }
      // The supplied account-scoped resolver already compares both partial
      // viewing observations and EOF receipts. Do not overwrite its decision
      // with only the most recent completed episode.
      if (detail.series &&
          widget.watchedEpisode == null &&
          widget.store != null &&
          personalAccount != null) {
        try {
          final local = widget.store!.completions.latest(
            personalAccount!,
            detail.id,
          );
          final remoteDate = DateTime.tryParse(
            '${object(target?.data['UserData'])['LastPlayedDate']}',
          );
          final localDate = DateTime.tryParse(
            '${object(local?.data['UserData'])['LastPlayedDate']}',
          );
          if (local != null &&
              (remoteDate == null || localDate!.isAfter(remoteDate))) {
            target = local;
          }
        } catch (e) {
          warning = safeError(e);
        }
      }
      final moveFocus =
          detail.series &&
          target != null &&
          focusIntent == focusRevision &&
          ((force && earlyFocusId != target.id) ||
              target.id != focusEpisode?.id ||
              (!historyLoaded && focusResume));
      final previousSeason = season;
      setState(() {
        historyLoaded = true;
        historyError = warning;
        focusEpisode = target;
        if (moveFocus) focusResume = true;
        if (moveFocus && splitDetail) detailTab = 1;
        item = detail;
        seasonError = seasonFailure == null
            ? null
            : '季列表读取失败：${safeError(seasonFailure)}';
        seasons = values;
        season =
            preferredSeason(values) ??
            (values.isEmpty
                ? seasonFailure == null
                      ? null
                      : season
                : values.any((value) => value.id == season)
                ? season
                : values.first.id);
      });
      if (moveFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              splitDetail &&
              focusIntent == focusRevision &&
              tabs.hasClients) {
            tabs.jumpToPage(1);
          }
        });
      }
      if (season != null) {
        if ((force && earlyEpisodeSeason != season) ||
            previousSeason != season ||
            (!episodeBusy && episodes.isEmpty)) {
          await loadEpisodes(reset: true, force: force);
        } else if (focusResume && episodes.isNotEmpty) {
          final at = episodes.indexWhere((e) => e.id == focusEpisode?.id);
          if (at >= 0) {
            if (!episodeBusy) focusResume = false;
            jumpEpisode(at);
          }
        }
      }
    } on BackgroundPaused {
      // Playback/background suspension cancels optional browsing. Keep the
      // last successful display until the existing resume path reloads it.
      if (mounted && revision == detailGeneration) {
        setState(() => episodesPaused = true);
      }
    } catch (e) {
      if (mounted && revision == detailGeneration) {
        setState(() {
          error = safeError(e);
          if (metadataBusy) metadataError = safeError(e);
          metadataBusy = false;
        });
      }
    } finally {
      if (mounted && revision == detailGeneration) setState(() => busy = false);
    }
  }

  Future<void> loadEpisodes({bool reset = false, bool force = false}) async {
    if (season == null || (episodeBusy && !reset)) return;
    final seriesId = item!.id, seasonId = season!;
    if (reset) {
      generation++;
      episodes = List.of(
        widget.browse
                ?.peek(BrowseRepository.episodeCatalogueKey(seriesId, seasonId))
                ?.items ??
            [],
      );
    }
    final revision = generation;
    setState(() {
      episodeBusy = true;
      episodeError = null;
      episodesPaused = false;
    });
    if (focusResume) {
      final cachedAt = episodes.indexWhere((e) => e.id == focusEpisode?.id);
      if (cachedAt >= 0) {
        // This is provisional: a cached season may have fewer following rows.
        // Resolve the same watched ID again once the current catalogue arrives.
        jumpEpisode(cachedAt);
      }
    }
    try {
      bool allowed() => mounted && revision == generation;
      final page =
          await (widget.browse?.episodeCatalogue(
                seriesId,
                seasonId,
                force: force,
                allowed: allowed,
              ) ??
              widget.api.episodeCatalogue(
                seriesId,
                seasonId,
                allowed: allowed,
              ));
      if (!mounted || revision != generation) return;
      setState(() {
        episodes = List.of(page.items);
      });
      if (focusResume) {
        focusResume = false;
        final at = episodes.indexWhere((e) => e.id == focusEpisode?.id);
        if (at >= 0) {
          jumpEpisode(at);
        }
      }
    } on BackgroundPaused {
      // A cancelled catalogue is incomplete, rather than a failed response.
      if (mounted && revision == generation) {
        setState(() => episodesPaused = true);
      }
    } catch (e) {
      if (mounted && revision == generation) {
        setState(() => episodeError = safeError(e));
      }
    } finally {
      if (mounted && revision == generation) {
        setState(() => episodeBusy = false);
      }
    }
  }

  void revealRange() {
    if (!rangeScroll.hasClients) return;
    final position = rangeScroll.position;
    final start = episodeRange * rangeWidth;
    final end = start + rangeWidth;
    if (start < position.pixels ||
        end > position.pixels + position.viewportDimension) {
      rangeScroll.jumpTo(
        (start - (position.viewportDimension - rangeWidth) / 2).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
    }
  }

  void trackRange() {
    if (!mounted || episodes.isEmpty || !episodeScroll.hasClients) return;
    final at =
        ((episodeScroll.offset - 8).clamp(0, double.infinity) / episodeHeight)
            .floor();
    final next = bands.bandOf(at.clamp(0, episodes.length - 1));
    if (next == episodeRange) return;
    setState(() => episodeRange = next);
    revealRange();
  }

  void jumpEpisode(int index, {int attempt = 0}) {
    if (!splitDetail && detailTab == 0) {
      pendingEpisodeIndex = index;
      return;
    }
    final revision = generation;
    final intent = focusRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          revision != generation ||
          intent != focusRevision ||
          index >= episodes.length) {
        return;
      }
      // A phone's episode tab can be attached before its first visible layout.
      // Resolve the scroll extent in that next layout rather than animating 0.
      if (!episodeScroll.hasClients ||
          !episodeScroll.position.hasContentDimensions ||
          episodeScroll.position.viewportDimension <= 0) {
        if (attempt < 3) {
          jumpEpisode(index, attempt: attempt + 1);
          WidgetsBinding.instance.scheduleFrame();
        }
        return;
      }
      final target = (8 + index * episodeHeight).clamp(
        0,
        episodeScroll.position.maxScrollExtent,
      );
      setState(() {
        pendingEpisodeIndex = null;
        locatingEpisode = true;
      });
      unawaited(
        episodeScroll
            .animateTo(
              target.toDouble(),
              duration: const Duration(milliseconds: 360),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() {
              if (mounted &&
                  revision == generation &&
                  intent == focusRevision) {
                setState(() => locatingEpisode = false);
              }
            }),
      );
      // Near the season end the list cannot scroll the target all the way to
      // the top; still select its range and keep the highlighted row visible.
      setState(() => episodeRange = bands.bandOf(index));
      revealRange();
    });
  }

  String rangeLabel(int index) => bands.labelAt(index);
  Future<void> chooseRange() async {
    final picked = await showSurface<int>(
      context,
      (_) => EpisodeBandPicker(
        count: rangeCount,
        selected: episodeRange,
        label: bands.labelAt,
      ),
    );
    if (mounted && picked != null) jumpRange(picked);
  }

  Future<void> play(MediaItem entry, {bool fromBeginning = false}) async {
    if (openingEntry != null) return;
    setState(() => openingEntry = entry);
    try {
      await widget.play(entry, source, fromBeginning);
    } finally {
      if (mounted) {
        setState(() => openingEntry = null);
        unawaited(load(force: true));
      }
    }
  }

  Duration resumeOf(MediaItem entry) => personalAccount == null
      ? entry.resume
      : widget.store?.resume(personalAccount!, entry).position ?? entry.resume;

  bool splitDetail = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    splitDetail = wideLayout(context);
    if (splitDetail && pendingEpisodeIndex != null) {
      jumpEpisode(pendingEpisodeIndex!);
    }
  }

  int detailTab = 0;
  int? pendingEpisodeIndex;
  bool locatingEpisode = false;
  MediaItem? openingEntry;
  late final tabs = PageController(initialPage: detailTab);

  @override
  Widget build(BuildContext context) {
    final entry = item ?? widget.item;
    final wide = wideLayout(context);
    return SurfacePage(
      title: 'Emby 详情',
      detail: true,
      prioritizeBackground: true,
      backgroundUrl: entry.backdropTag.isNotEmpty
          ? widget.api.imageUrl(entry, backdrop: true)
          : posterUrl(widget.api, entry),
      backgroundKind: entry.backdropTag.isNotEmpty
          ? PosterKind.artwork
          : PosterKind.poster,
      blurBackground: entry.backdropTag.isEmpty,
      child: busy && item == null
          ? const MessagePanel('正在读取详情', busy: true)
          : error != null && item == null
          ? MessagePanel(error!, retry: load)
          : Column(
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '更新失败，显示本机缓存：$error',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                SizedBox(
                  height: 2,
                  child: busy
                      ? LinearProgressIndicator(
                          color: accentColor(context),
                          minHeight: 2,
                        )
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: wide ? 22 : 18,
                            fontWeight: wide
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        CupertinoIcons.cloud,
                        size: 14,
                        color: secondaryColor(context),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Emby',
                        style: TextStyle(
                          fontSize: 12,
                          color: secondaryColor(context),
                        ),
                      ),
                      if (wide) const SizedBox(width: 28),
                    ],
                  ),
                ),
                if (entry.series && !wide)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: CupertinoSlidingSegmentedControl<int>(
                        groupValue: detailTab,
                        children: const {0: Text('简介'), 1: Text('剧集')},
                        onValueChanged: (value) {
                          if (value == null) return;
                          setState(() => detailTab = value);
                          tabs
                              .animateToPage(
                                value,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOut,
                              )
                              .then((_) {
                                if (mounted && value == 1) {
                                  revealEpisodeTarget();
                                }
                              });
                        },
                      ),
                    ),
                  ),
                Expanded(
                  child: entry.series
                      ? wide
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(child: info(entry)),
                                    const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      child: VerticalDivider(
                                        width: 1,
                                        thickness: 1,
                                      ),
                                    ),
                                    Expanded(child: episodePanel()),
                                  ],
                                ),
                              )
                            : PageView(
                                controller: tabs,
                                onPageChanged: (value) {
                                  setState(() => detailTab = value);
                                  if (value == 1) revealEpisodeTarget();
                                },
                                children: [info(entry), episodePanel()],
                              )
                      : info(entry),
                ),
              ],
            ),
    );
  }

  void revealEpisodeTarget() {
    final at =
        pendingEpisodeIndex ??
        episodes.indexWhere((e) => e.id == focusEpisode?.id);
    if (at >= 0) jumpEpisode(at);
  }

  Widget info(MediaItem entry) {
    final phone = phoneLayout(context);
    final color = labelColor(context);
    final valueStyle = TextStyle(
      color: color.withValues(alpha: .85),
      fontSize: 13,
      height: 1.5,
    );
    final original = entry.data['OriginalTitle']?.toString() ?? '';
    final genres = (entry.data['Genres'] as List? ?? [])
        .map((e) => '$e')
        .toList();
    final sources = objects(entry.data['MediaSources']);
    Widget row(String name, String value) => value.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text.rich(
              TextSpan(
                style: valueStyle.copyWith(height: 1.35),
                children: [
                  TextSpan(
                    text: '$name: ',
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: value),
                ],
              ),
            ),
          );
    Widget synopsisText() => widget.store != null && personalAccount != null
        ? SynopsisTranslation(
            service: widget.store!.translation,
            account: personalAccount!,
            item: entry,
            style: valueStyle,
            active: !entry.series || wideLayout(context) || detailTab == 0,
            currentAccount: () => widget.api.session == personalAccount,
            backgroundWork: widget.api.backgroundWork,
          )
        : Text(
            entry.overview.isEmpty ? '暂无简介' : entry.overview,
            style: valueStyle,
          );
    // This is the same verified history target as the episode highlight. Do
    // not offer the first episode while a newer viewing record is still read.
    final target = entry.playable
        ? entry
        : historyLoaded
        ? focusEpisode ?? episodes.firstOrNull
        : null;
    final continuing =
        target != null &&
        (target.id == focusEpisode?.id || resumeOf(target) > Duration.zero);
    final episodeNumber = target?.data['IndexNumber'];
    final playLabel = openingEntry != null
        ? '正在打开'
        : target == null
        ? '正在准备播放信息'
        : continuing
        ? target.type == 'Episode' && episodeNumber != null
              ? '继续观看第 $episodeNumber 集'
              : '继续观看'
        : '播放';
    final buttonColor = Theme.of(context).colorScheme;
    Widget playButton() => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: CupertinoButton(
          key: const Key('synopsis-play'),
          color: buttonColor.primary,
          disabledColor: buttonColor.primary.withValues(alpha: .35),
          borderRadius: BorderRadius.circular(8),
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          onPressed: target == null || openingEntry != null
              ? null
              : () => play(target),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.play_fill,
                size: 14,
                color: buttonColor.onPrimary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  playLabel,
                  style: TextStyle(
                    color: buttonColor.onPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return SingleChildScrollView(
      key: const PageStorageKey('detail-info'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (original.isNotEmpty && original != entry.title)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                original,
                style: valueStyle.copyWith(
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          if (widget.personal != null &&
              personalAccount != null &&
              widget.api.session == personalAccount)
            SaveMediaButtons(
              library: widget.personal!,
              account: personalAccount!,
              item: entry,
              sync: widget.personalSync,
              onChanged: () => load(force: true),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (posterUrl(widget.api, entry) != null)
                Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      key: const Key('detail-poster'),
                      width: phoneValue(context, 104, 130),
                      height: phoneValue(context, 156, 195),
                      child: PosterActionRegion(
                        item: entry,
                        externalMenu:
                            widget.personal != null &&
                            widget.personalSync != null,
                        detail: true,
                        onChanged: () => load(force: true),
                        child: Poster(url: posterUrl(widget.api, entry)),
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: SizedBox(
                  height: phoneValue(context, 156, 195),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            key: const Key('phone-detail-metadata'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              row('评分', entry.rating),
                              row('年份', entry.year),
                              row(
                                '时长',
                                entry.duration.inMinutes > 0
                                    ? '${entry.duration.inMinutes} 分钟'
                                    : '',
                              ),
                              row(
                                '分级',
                                entry.data['OfficialRating']?.toString() ?? '',
                              ),
                              row('类型', genres.join(' / ')),
                            ],
                          ),
                        ),
                      ),
                      playButton(),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (!phone) ...[
            const SizedBox(height: 16),
            Divider(color: color.withValues(alpha: .15)),
            const SizedBox(height: 8),
            if (entry.rating.isNotEmpty) ...[
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '评分: ',
                    style: valueStyle.copyWith(fontWeight: FontWeight.w600),
                  ),
                  for (var i = 0; i < 5; i++)
                    Icon(
                      (double.tryParse(entry.rating) ?? 0) >= (i + 1) * 2
                          ? CupertinoIcons.star_fill
                          : (double.tryParse(entry.rating) ?? 0) > i * 2
                          ? CupertinoIcons.star_lefthalf_fill
                          : CupertinoIcons.star,
                      size: 14,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFFFD761)
                          : const Color(0xFF876000),
                    ),
                  Text(
                    ' ${entry.rating}',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFFFD761)
                          : const Color(0xFF876000),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
            if (genres.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final genre in genres)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: color.withValues(alpha: .12),
                          width: .5,
                        ),
                      ),
                      child: Text(
                        genre,
                        style: TextStyle(
                          fontSize: 12,
                          color: secondaryColor(context),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
          if (objects(entry.data['People']).isNotEmpty) ...[
            const SizedBox(height: 20),
            PeopleRail(
              api: widget.api,
              people: objects(entry.data['People']),
              onItem: (value) async {
                await Navigator.push(
                  context,
                  CupertinoPageRoute<void>(
                    builder: (_) => DetailPage(
                      item: value,
                      api: widget.api,
                      play: widget.play,
                      browse: widget.browse,
                      store: widget.store,
                      personal: widget.personal,
                      personalSync: widget.personalSync,
                      watchedEpisode: widget.watchedEpisode,
                    ),
                  ),
                );
              },
            ),
          ] else ...[
            const SizedBox(height: 20),
            const Text(
              '演职员',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              metadataBusy
                  ? '正在读取演职员…'
                  : metadataError != null
                  ? '演职员读取失败，请重试'
                  : 'Emby 未提供演职员信息',
              style: TextStyle(color: secondaryColor(context)),
            ),
            if (metadataError != null)
              CupertinoButton(
                onPressed: () => load(force: true),
                child: const Text('重试演职员'),
              ),
          ],
          if (entry.playable) ...[
            if (sources.length > 1) ...[
              const SizedBox(height: 16),
              SettingsRow(
                '媒体版本',
                subtitle: sourceDescription(
                  sources.firstWhere(
                    (s) => s['Id']?.toString() == source,
                    orElse: () => sources.first,
                  ),
                ),
                onTap: () async {
                  final selected = await showSurface<String>(
                    context,
                    (context) => SelectionMenu(
                      label: '媒体版本',
                      children: [
                        for (final value in sources)
                          SelectionRow(
                            sourceDescription(value),
                            selected:
                                value['Id']?.toString() ==
                                (source ?? sources.first['Id']?.toString()),
                            onTap: () =>
                                Navigator.pop(context, value['Id']?.toString()),
                          ),
                      ],
                    ),
                  );
                  if (mounted && selected != null) {
                    setState(() => source = selected);
                  }
                },
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (resumeOf(entry) > Duration.zero)
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    onPressed: () => play(entry, fromBeginning: true),
                    child: Text(
                      '从头播放',
                      style: TextStyle(
                        fontSize: 14,
                        color: accentColor(context),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            WatchProgress(
              item: entry,
              account: personalAccount,
              store: widget.store,
            ),
          ],
          ...[
            const SizedBox(height: 16),
            Text(
              '简介',
              style: valueStyle.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            KeyedSubtree(
              key: Key(phone ? 'phone-detail-synopsis' : 'detail-synopsis'),
              child: synopsisText(),
            ),
          ],
        ],
      ),
    );
  }

  Widget episodePanel() => Listener(
    onPointerDown: (_) {
      focusRevision++;
      focusResume = false;
    },
    child: Column(
      children: [
        if (locatingEpisode)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('正在定位到上次观看的剧集…', key: Key('episode-locating')),
          ),
        if (focusEpisode != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '上次观看：第 ${focusEpisode!.data['ParentIndexNumber'] ?? "?"} 季 · 第 ${focusEpisode!.data['IndexNumber'] ?? "?"} 集',
                  style: TextStyle(fontSize: 13, color: labelColor(context)),
                ),
                const SizedBox(height: 4),
                WatchProgress(
                  item:
                      episodes
                          .where((e) => e.id == focusEpisode!.id)
                          .firstOrNull ??
                      focusEpisode!,
                  account: personalAccount,
                  store: widget.store,
                ),
              ],
            ),
          ),
        if (seasons.isNotEmpty)
          Container(
            height: 40,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final entry in seasons)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      onPressed: () {
                        if (season == entry.id) return;
                        setState(() {
                          focusRevision++;
                          season = entry.id;
                          focusResume = false;
                          episodeRange = 0;
                        });
                        if (episodeScroll.hasClients) episodeScroll.jumpTo(0);
                        if (rangeScroll.hasClients) rangeScroll.jumpTo(0);
                        loadEpisodes(reset: true);
                      },
                      child: Text(
                        entry.title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: season == entry.id
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: season == entry.id
                              ? accentColor(context)
                              : secondaryColor(context),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        if (episodes.isNotEmpty)
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: ListView.builder(
                    key: const Key('episode-ranges'),
                    controller: rangeScroll,
                    scrollDirection: Axis.horizontal,
                    itemExtent: rangeWidth,
                    itemCount: rangeCount,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 5,
                      ),
                      child: CupertinoButton(
                        key: ValueKey('episode-range-$index'),
                        padding: EdgeInsets.zero,
                        color: episodeRange == index
                            ? accentColor(context).withValues(alpha: .14)
                            : null,
                        onPressed: () {
                          focusRevision++;
                          focusResume = false;
                          jumpRange(index);
                        },
                        child: Text(
                          rangeLabel(index),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: episodeRange == index
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: episodeRange == index
                                ? accentColor(context)
                                : secondaryColor(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                CupertinoButton(
                  key: const Key('episode-ranges-all'),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onPressed: chooseRange,
                  child: const Icon(
                    CupertinoIcons.list_bullet,
                    size: 20,
                    semanticLabel: '选择集数区间',
                  ),
                ),
              ],
            ),
          ),
        if (historyError != null)
          SettingsRow(
            historyError!,
            subtitle: '点击重试观看记录',
            onTap: () => load(force: true),
          ),
        if (seasonError != null && (episodes.isNotEmpty || seasons.isNotEmpty))
          SettingsRow(
            seasonError!,
            subtitle: '点击重试季列表',
            onTap: () => load(force: true),
          ),
        if (episodeError != null && episodes.isNotEmpty)
          SettingsRow(
            '更新失败，显示本机缓存',
            subtitle: episodeError,
            onTap: () => loadEpisodes(force: true),
          ),
        if (focusEpisode != null &&
            !episodes.any((e) => e.id == focusEpisode!.id) &&
            (season == focusEpisode!.data['SeasonId'] ||
                seasons
                        .where((s) => s.id == season)
                        .firstOrNull
                        ?.data['IndexNumber'] ==
                    focusEpisode!.data['ParentIndexNumber']))
          SettingsRow(
            '上次观看',
            subtitle: focusEpisode!.title,
            icon: CupertinoIcons.play_circle,
            onTap: () => play(focusEpisode!),
          ),
        Expanded(
          child: NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              if (notification.depth == 0 &&
                  notification.direction != ScrollDirection.idle) {
                focusRevision++;
                focusResume = false;
              }
              return false;
            },
            child: episodes.isEmpty
                ? MessagePanel(
                    episodeError ??
                        seasonError ??
                        (episodeBusy
                            ? '正在读取剧集'
                            : episodesPaused
                            ? '剧集读取已暂停'
                            : '暂无可用剧集'),
                    busy: episodeBusy,
                    retry: episodeError != null
                        ? loadEpisodes
                        : seasonError != null || episodesPaused
                        ? () => load(force: true)
                        : null,
                    icon: CupertinoIcons.film,
                  )
                : ListView.builder(
                    key: const PageStorageKey('detail-episodes'),
                    controller: episodeScroll,
                    itemExtent: episodeHeight,
                    padding: const EdgeInsets.only(top: 8, bottom: 24),
                    itemCount: episodes.length,
                    itemBuilder: (context, index) {
                      final entry = episodes[index];
                      return CupertinoButton(
                        key: ValueKey('detail-episode-${entry.id}'),
                        color: entry.id == focusEpisode?.id
                            ? accentColor(context).withValues(alpha: .14)
                            : null,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        onPressed: () => play(entry),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: SizedBox(
                                width: 60 * posterAspectRatio,
                                height: 60,
                                child: PosterActionRegion(
                                  item: entry,
                                  externalMenu: true,
                                  detail: true,
                                  onChanged: () => load(force: true),
                                  child: Poster(
                                    url: posterUrl(
                                      widget.api,
                                      entry,
                                      series: item,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: PosterActionTitle(
                                item: entry,
                                detail: true,
                                onChanged: () => load(force: true),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      entry.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: labelColor(context),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      entry.id == focusEpisode?.id
                                          ? '上次观看 · 第 ${entry.data['IndexNumber'] ?? "?"} 集'
                                          : '第 ${entry.data['IndexNumber'] ?? index + 1} 集',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: secondaryColor(context),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    WatchProgress(
                                      item: entry,
                                      account: personalAccount,
                                      store: widget.store,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              CupertinoIcons.play_circle,
                              size: 24,
                              color: secondaryColor(context),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    ),
  );
}
