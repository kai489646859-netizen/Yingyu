import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../ui/expansion_chevron.dart';
import '../ui/anchored_menu.dart';
import '../ui/surface.dart';
import '../core/browse_cache.dart';
import '../core/emby.dart';
import '../core/models.dart';
import '../core/episode_bands.dart';
import '../ui/episode_band_picker.dart';

/// Only requested catalogue metadata. Playback's optional background work stays
/// suspended; opening the picker never prepares media or requests artwork.
class EpisodeMenuData {
  EpisodeMenuData(this.api, {this.browse});
  final EmbyClient api;
  final BrowseRepository? browse;
  String? _series;
  List<MediaItem>? _seasons;
  final _catalogues = <String, List<MediaItem>>{};
  BrowseRepository? get activeBrowse => browse?.current == true ? browse : null;

  Future<List<MediaItem>> seasons(String series) async {
    if (_series != series) {
      _series = series;
      _seasons = null;
      _catalogues.clear();
    }
    return _seasons ??= List.of(
      (activeBrowse?.peek('seasons:$series')?.items ??
              (await api.seasons(series)).items)
          .where((item) => item.id.isNotEmpty),
    );
  }

  Future<List<MediaItem>> episodes(
    String series,
    String season,
    bool Function() allowed, {
    String? currentId,
  }) async {
    final key = BrowseRepository.episodeCatalogueKey(series, season);
    final saved = _catalogues.remove(key);
    bool containsCurrent(List<MediaItem> items) =>
        currentId == null || items.any((item) => item.id == currentId);
    if (saved != null && containsCurrent(saved)) {
      _catalogues[key] = saved;
      return saved;
    }
    final cached = activeBrowse?.peek(key);
    final items = cached != null && containsCurrent(cached.items)
        ? cached.items
        : (await api.episodeCatalogue(series, season, allowed: allowed)).items;
    if (!allowed()) throw const AppFailure('剧集请求已暂停');
    final result = items.where((item) {
      final owner = item.data['SeriesId']?.toString();
      final parent = item.data['SeasonId']?.toString();
      return item.type == 'Episode' &&
          item.playable &&
          item.id.isNotEmpty &&
          (owner == null || owner == series) &&
          (parent == null || parent == season);
    }).toList();
    // A small per-player cache also covers entries opened from Continue Watching.
    while (_catalogues.length >= 3) {
      _catalogues.remove(_catalogues.keys.first);
    }
    _catalogues[key] = result;
    return result;
  }
}

class EpisodeMenu extends StatefulWidget {
  const EpisodeMenu({super.key, required this.current, required this.data});
  final MediaItem current;
  final EpisodeMenuData data;
  @override
  State<EpisodeMenu> createState() => _EpisodeMenuState();
}

class _EpisodeMenuState extends State<EpisodeMenu> {
  final scroll = ScrollController();
  List<MediaItem> episodes = [];
  String series = '', season = '';
  String? error;
  bool busy = true;
  bool rangeOpen = false;
  bool rangeOpensUp = false;
  int generation = 0, range = 0;
  List<MediaItem>? _bandSource;
  EpisodeBands? _bands;
  EpisodeBands get bands {
    if (!identical(_bandSource, episodes)) { _bandSource = episodes; _bands = EpisodeBands(episodes); }
    return _bands!;
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    generation++;
    scroll.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final revision = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var current = widget.current;
      if ((current.data['SeriesId']?.toString() ?? '').isEmpty ||
          (current.data['SeasonId']?.toString() ?? '').isEmpty) {
        current = await widget.data.api.detail(current.id);
      }
      if (!mounted || revision != generation) return;
      series = current.data['SeriesId']?.toString() ?? '';
      season = current.data['SeasonId']?.toString() ?? '';
      if (series.isEmpty) throw const AppFailure('缺少所属剧集资料，请重试');
      if (season.isEmpty) {
        final values = await widget.data.seasons(series);
        if (!mounted || revision != generation) return;
        season =
            values
                .where(
                  (s) =>
                      s.data['IndexNumber'] != null &&
                      s.data['IndexNumber'] ==
                          current.data['ParentIndexNumber'],
                )
                .firstOrNull
                ?.id ??
            '';
      }
      if (season.isEmpty) throw const AppFailure('无法确认当前分集列表，请重试');
      final values = await widget.data.episodes(
        series,
        season,
        () => mounted && revision == generation,
        currentId: widget.current.id,
      );
      if (!mounted || revision != generation) return;
      final at = values.indexWhere((item) => item.id == widget.current.id);
      if (values.isNotEmpty && at < 0) {
        throw const AppFailure('列表未返回正在播放的分集，请重试');
      }
      setState(() {
        episodes = values;
        range = at < 0 ? 0 : bands.bandOf(at);
        busy = false;
      });
      reveal(at < 0 ? 0 : bands.inBand(range).indexOf(at));
    } catch (e) {
      if (mounted && revision == generation) {
        setState(() {
          error = safeError(e);
          busy = false;
        });
      }
    }
  }

  ({double width, double height, double bottom, bool landscape}) get geometry {
    final size = MediaQuery.sizeOf(context),
        safe = MediaQuery.paddingOf(context);
    final landscape = size.width > size.height;
    final available = size.height - safe.vertical;
    final short = landscape && available < 520;
    final bottom = short
        ? 12.0
        : landscape
        ? 82.0
        : 16.0;
    final height = math.min(
      440.0,
      math.min(available * (short ? .9 : .68), available - bottom - 12),
    );
    final width = math.min(
      336.0,
      math.min(size.width - safe.horizontal - 32, height * .82),
    );
    return (width: width, height: height, bottom: bottom, landscape: landscape);
  }

  void reveal(int at) {
    final revision = generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != generation || !scroll.hasClients) return;
      final cell = (geometry.width - 32 - 32) / 5;
      scroll.jumpTo(
        ((at ~/ 5) * (cell + 8)).clamp(0, scroll.position.maxScrollExtent),
      );
    });
  }

  String number(int index) =>
      '${episodes[index].data['IndexNumber'] ?? index + 1}';
  String rangeLabel(int index) => bands.labelAt(index);

  Widget picker<T>({
    required Key key,
    required String label,
    required T selected,
    required List<PopupMenuEntry<T>> entries,
    required Iterable<String> labels,
    required ValueChanged<T> choose,
  }) => AnchoredMenuButton<T>(
    key: key,
    id: 'episode-picker-$key',
    label: label,
    initialValue: selected,
    menuWidth: compactMenuWidth(context, labels),
    maxHeight: 220,
    onOpenChanged: (open) {
      if (mounted) setState(() => rangeOpen = open);
    },
    onDirectionChanged: (up) {
      if (mounted && rangeOpensUp != up) setState(() => rangeOpensUp = up);
    },
    onSelected: (value) {
      if (!mounted) return;
      setState(() => rangeOpen = false);
      choose(value);
    },
    items: (_) => entries,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(width: 4),
          ExpansionChevron(
            expanded: rangeOpen,
            opensUp: rangeOpensUp,
            size: 12,
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final shape = geometry;
    final width = shape.width, height = shape.height, bottom = shape.bottom;
    final landscape = shape.landscape;
    final accent = Theme.of(context).colorScheme.primary;
    final panel = SizedBox(
      key: const Key('player-episode-panel'),
      width: width,
      height: height,
      child: Material(
        color: const Color(0xFF19191D),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            SizedBox(
              height: 44,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '选集',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Tooltip(
                      message: '关闭选集',
                      child: CupertinoButton(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(44, 44),
                        onPressed: () => Navigator.pop(context),
                        child: Icon(
                          CupertinoIcons.xmark,
                          color: accent,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (episodes.isNotEmpty && !busy && error == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 16, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 130,
                      child: CupertinoButton(
                        key: const Key('player-episode-range'),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        onPressed: () async {
                          setState(() => rangeOpen = true);
                          final picked = await showSurface<int>(
                            context,
                            playerMenu: true,
                            (_) => EpisodeBandPicker(
                              count: bands.count, label: bands.labelAt,
                              selected: range,
                            ),
                          );
                          if (mounted) setState(() => rangeOpen = false);
                          if (mounted && picked != null) {
                            setState(() => range = picked);
                            reveal(0);
                          }
                        },
                        child: Row(children: [Expanded(child: Text(rangeLabel(range), maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ExpansionChevron(expanded: rangeOpen, opensUp: false, size: 12)]),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '共 ${episodes.length} 集',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: busy
                  ? const Center(child: CupertinoActivityIndicator())
                  : error != null
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(error!, textAlign: TextAlign.center),
                            TextButton(
                              onPressed: load,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : episodes.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无可播放分集',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(scrollbars: false),
                      child: RawScrollbar(
                        controller: scroll,
                        thumbVisibility: true,
                        thickness: 3,
                        radius: const Radius.circular(1.5),
                        thumbColor: const Color(0xE6B0B0B0),
                        child: GridView.builder(
                          key: const Key('player-episode-grid'),
                          controller: scroll,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 5,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                          itemCount: bands.inBand(range).length,
                          itemBuilder: (context, i) {
                            final at = bands.inBand(range)[i],
                                item = episodes[at];
                            final selected = item.id == widget.current.id;
                            return Semantics(
                              selected: selected,
                              button: true,
                              label:
                                  '第 ${number(at)} 集${selected ? '，当前播放' : ''}，${item.title}',
                              child: Tooltip(
                                message: item.title,
                                child: Material(
                                  color: selected
                                      ? accent.withValues(alpha: .22)
                                      : Colors.white.withValues(alpha: .07),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(
                                      color: selected
                                          ? accent
                                          : Colors.transparent,
                                    ),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    key: ValueKey('player-episode-${item.id}'),
                                    onTap: () => Navigator.pop(context, item),
                                    child: Center(
                                      child: Text(
                                        number(at),
                                        maxLines: 1,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: selected
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: selected
                                              ? accent
                                              : Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
    return AnchoredSurface(
      width: width,
      maxHeight: height,
      child: panel,
      unanchored: (child) => SafeArea(
        child: Align(
          alignment: landscape ? Alignment.bottomRight : Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: landscape ? 20 : 12,
              bottom: bottom,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
