import 'dart:async';
import 'dart:io' show File;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'poster_service.dart';
import 'image_cache_budget.dart';
import 'persistent_image_files.dart';
import 'poster_press.dart';
import 'detail_artwork_priority.dart';
import '../core/image_loading.dart';
import '../core/image_identity.dart';
export 'image_cache_budget.dart' show imageGB;

// Independent disk categories and byte budgets share one HTTP scheduler.
final _imageDownloads = PosterFileService();
void setImageDiagnosticSink(void Function(String) sink) {
  _imageDownloads.diagnostic = sink;
}

void setImageLoadSpeed(ImageLoadSpeed value) {
  _imageDownloads.spacing = value.interval;
}

void setImageRequestLimit(int value) {
  _imageDownloads.requestLimit = value;
}

final imageCacheBudget = ImageCacheBudget();
CacheManager posterCache = BudgetCacheManager(
  Config(
    'yingyu-posters-v1',
    fileSystem: PersistentImageFiles('yingyu-posters-v1'),
    stalePeriod: const Duration(days: 36500),
    maxNrOfCacheObjects: 2147483647,
    fileService: _imageDownloads,
  ),
  imageCacheBudget,
);
CacheManager artworkCache = BudgetCacheManager(
  Config(
    'yingyu-detail-artwork-v1',
    fileSystem: PersistentImageFiles('yingyu-detail-artwork-v1'),
    stalePeriod: const Duration(days: 36500),
    maxNrOfCacheObjects: 2147483647,
    fileService: _imageDownloads,
  ),
  imageCacheBudget,
  isArtwork: true,
);

final actorCacheBudget = ImageCacheBudget(limitBytes: imageGB);
final landscapeCacheBudget = ImageCacheBudget(limitBytes: imageGB);
CacheManager landscapeCache = BudgetCacheManager(
  Config(
    'yingyu-landscape-v1',
    fileSystem: PersistentImageFiles('yingyu-landscape-v1'),
    stalePeriod: const Duration(days: 36500),
    maxNrOfCacheObjects: 2147483647,
    fileService: _imageDownloads,
  ),
  landscapeCacheBudget,
  reuseFrom: [artworkCache, posterCache],
);
CacheManager actorCache = BudgetCacheManager(
  Config(
    'yingyu-people-v1',
    fileSystem: PersistentImageFiles('yingyu-people-v1'),
    stalePeriod: const Duration(days: 36500),
    maxNrOfCacheObjects: 2147483647,
    fileService: _imageDownloads,
  ),
  actorCacheBudget,
);
CacheManager cacheFor(PosterKind kind) => switch (kind) {
  PosterKind.actor => actorCache,
  PosterKind.landscape => landscapeCache,
  PosterKind.artwork => artworkCache,
  PosterKind.poster => posterCache,
};

enum PosterKind { poster, artwork, actor, landscape }

bool _artworkKey(String url, PosterKind kind) =>
    kind == PosterKind.artwork ||
    kind == PosterKind.landscape &&
        (Uri.tryParse(url)?.path.contains('/Images/Backdrop/') ?? false);

class Poster extends StatefulWidget {
  const Poster({
    super.key,
    required this.url,
    this.backdrop = false,
    this.active = true,
    this.kind = PosterKind.poster,
    this.fit = BoxFit.cover,
    this.priorityImage = false,
  });
  final String? url;
  final bool backdrop, active;
  final PosterKind kind;
  final BoxFit fit;
  final bool priorityImage;
  @override
  State<Poster> createState() => _PosterState();
}

class _PosterState extends State<Poster> with WidgetsBindingObserver {
  String? pinnedImage;
  void pinImage() {
    final url = widget.url;
    final key = url == null
        ? null
        : SharedImageIdentity.key(url, artwork: _artworkKey(url, widget.kind));
    if (key == pinnedImage) return;
    if (pinnedImage != null) imageCacheBudget.references?.unpin(pinnedImage!);
    pinnedImage = key;
    if (key != null) imageCacheBudget.references?.pin(key);
  }

  final visibilityKey = UniqueKey();
  bool visible = false, started = false, foreground = true;
  bool wasPermitted = false, imageReady = false;
  int attempt = 0;
  int retries = 0;
  Timer? retry;
  File? localImage;
  String? localLookup;
  bool localChecked = false, localRecorded = false;
  int localGeneration = 0;
  FileInfo? localInfo;
  void markImageReady() {
    imageReady = true;
    if (widget.priorityImage) {
      DetailArtworkPriority.complete(context, widget.url);
    }
  }

  Future<void> readLocalImage(String url, PosterKind kind) async {
    final generation = ++localGeneration;
    FileInfo? found;
    try {
      final cache = cacheFor(kind);
      final key = SharedImageIdentity.key(url, artwork: _artworkKey(url, kind));
      // This API only reads the existing disk entry; it never starts a download.
      found = cache is BudgetCacheManager
          ? await cache.sharedFile(url, key)
          : await cache.getFileFromCache(key);
      if (found != null && !await found.file.exists()) found = null;
    } catch (_) {
      // A missing/corrupt local image stays a placeholder until downloads resume.
    }
    if (!mounted ||
        generation != localGeneration ||
        widget.url != url ||
        widget.kind != kind) {
      return;
    }
    setState(() {
      localChecked = true;
      localInfo = found;
      localImage = found == null ? null : File(found.file.path);
    });
  }

  void recordLocalUse() {
    if (localRecorded || localInfo == null || widget.url == null) return;
    localRecorded = true;
    final cache = cacheFor(widget.kind);
    if (cache is BudgetCacheManager) {
      // Prefetch is not a view. Touch LRU only once this poster is visible,
      // without making decoded pixels wait for quota scans or disk accounting.
      unawaited(
        cache.budget
            .record(
              cache,
              localInfo!,
              SharedImageIdentity.key(
                widget.url!,
                artwork: _artworkKey(widget.url!, widget.kind),
              ),
            )
            .catchError((Object _) {}),
      );
    }
  }

  void retryVisible() {
    if (!mounted || !wasPermitted) return;
    setState(() => attempt++);
  }

  Widget failure(BuildContext context) {
    if (PosterDemand.loadingPaused.value) return placeholder(context);
    if (widget.priorityImage) {
      DetailArtworkPriority.complete(context, widget.url);
    }
    if (wasPermitted && retry == null && retries < 3) {
      retry = Timer(Duration(seconds: 30 * (1 << retries++)), () {
        retry = null;
        retryVisible();
      });
    }
    return Semantics(
      label: '图片加载失败，点击重试',
      button: true,
      child: GestureDetector(
        onTap: retryVisible,
        child: placeholder(context, failed: true),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    pinImage();
    final controller = VisibilityDetectorController.instance;
    if (controller.updateInterval > const Duration(milliseconds: 100)) {
      controller.updateInterval = const Duration(milliseconds: 100);
    }
    WidgetsBinding.instance.addObserver(this);
    PosterDemand.loadingPaused.addListener(demandChanged);
  }

  void demandChanged() {
    // A rail can disappear while the widget tree is being disposed.
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      retry?.cancel();
      retry = null;
      PosterDemand.set(visibilityKey, null);
      wasPermitted = false;
    }
    if (mounted) {
      setState(() => foreground = state == AppLifecycleState.resumed);
    }
  }

  @override
  void didUpdateWidget(Poster old) {
    super.didUpdateWidget(old);
    pinImage();
    if (old.url != widget.url || old.kind != widget.kind) started = false;
    if (old.url != widget.url || old.kind != widget.kind) {
      imageReady = false;
      localImage = null;
      localLookup = null;
      localChecked = false;
      localRecorded = false;
      localInfo = null;
      localGeneration++;
      retry?.cancel();
      retry = null;
      retries = 0;
    }
    if (!widget.active || old.url != widget.url) {
      PosterDemand.set(visibilityKey, null);
    }
  }

  @override
  void dispose() {
    if (pinnedImage != null) imageCacheBudget.references?.unpin(pinnedImage!);
    retry?.cancel();
    PosterDemand.loadingPaused.removeListener(demandChanged);
    PosterDemand.set(visibilityKey, null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localEligible =
        foreground &&
        widget.active &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    final eligible = visible && localEligible;
    final mayDownload = DetailArtworkPriority.mayDownload(
      context,
      first: widget.priorityImage,
      url: widget.url,
    );
    PosterDemand.set(
      visibilityKey,
      eligible && mayDownload ? widget.url : null,
      actor: widget.kind == PosterKind.actor,
    );
    final permitted =
        eligible && mayDownload && !PosterDemand.loadingPaused.value;
    if (localEligible &&
        !imageReady &&
        localImage == null &&
        widget.url != null &&
        localLookup != widget.url) {
      localLookup = widget.url;
      unawaited(readLocalImage(widget.url!, widget.kind));
    }
    if (eligible) recordLocalUse();
    if (!permitted) {
      retry?.cancel();
      retry = null;
    }
    if (permitted && !wasPermitted && !imageReady) attempt++;
    wasPermitted = permitted;
    if (permitted && localChecked && localImage == null && widget.url != null) {
      started = true;
    }
    final content = VisibilityDetector(
      key: visibilityKey,
      onVisibilityChanged: (info) {
        if (info.visibleFraction <= 0) PosterDemand.set(visibilityKey, null);
        if (mounted && visible != (info.visibleFraction > 0)) {
          setState(() => visible = info.visibleFraction > 0);
        }
      },
      child: localImage != null
          ? Image.file(
              localImage!,
              fit: widget.fit,
              cacheWidth: widget.backdrop
                  ? 1280
                  : widget.kind == PosterKind.landscape
                  ? 640
                  : 360,
              gaplessPlayback: true,
              frameBuilder: (_, child, frame, _) {
                if (frame != null) markImageReady();
                if (frame == null && widget.kind == PosterKind.actor) {
                  return placeholder(context);
                }
                return child;
              },
              errorBuilder: (_, _, _) {
                final failed = localImage;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && identical(localImage, failed)) {
                    setState(() => localImage = null);
                  }
                });
                return placeholder(context);
              },
            )
          : started && widget.url != null && widget.kind == PosterKind.actor
          ? Image(
              key: ValueKey('${widget.url}:$attempt'),
              image: ResizeImage.resizeIfNeeded(
                360,
                null,
                CachedNetworkImageProvider(
                  widget.url!,
                  cacheManager: actorCache,
                  cacheKey: SharedImageIdentity.key(
                    widget.url!,
                    artwork: false,
                  ),
                ),
              ),
              fit: BoxFit.cover,
              gaplessPlayback: false,
              frameBuilder: (_, child, frame, _) {
                if (frame == null) return placeholder(context);
                markImageReady();
                return child;
              },
              errorBuilder: (_, _, _) => failure(context),
            )
          : started && widget.url != null
          ? CachedNetworkImage(
              key: ValueKey('${widget.url}:$attempt'),
              imageUrl: widget.url!,
              cacheKey: SharedImageIdentity.key(
                widget.url!,
                artwork: _artworkKey(widget.url!, widget.kind),
              ),
              cacheManager: cacheFor(widget.kind),
              memCacheWidth: widget.backdrop
                  ? 1280
                  : widget.kind == PosterKind.landscape
                  ? 640
                  : 360,
              fit: widget.fit,
              imageBuilder: (context, provider) {
                markImageReady();
                return Image(image: provider, fit: widget.fit);
              },
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              placeholderFadeInDuration: Duration.zero,
              placeholder: (_, _) => placeholder(context),
              errorWidget: (_, _, _) => failure(context),
            )
          : placeholder(context),
    );
    return widget.kind == PosterKind.poster ||
            widget.kind == PosterKind.landscape
        ? PosterPressFeedback(
            key: ValueKey(widget.url),
            active: localEligible,
            child: content,
          )
        : content;
  }

  Widget placeholder(BuildContext context, {bool failed = false}) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(
      child: Icon(
        failed
            ? CupertinoIcons.photo
            : widget.kind == PosterKind.actor
            ? CupertinoIcons.person_fill
            : CupertinoIcons.film,
        size: 28,
        color: Theme.of(
          context,
        ).colorScheme.onSurfaceVariant.withValues(alpha: .5),
      ),
    ),
  );
}
