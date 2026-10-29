import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/browse_cache.dart';
import '../core/interface_preferences.dart';
import '../core/image_loading.dart';
import '../core/appearance.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'licenses.dart';
import 'logs.dart';
import 'poster.dart';
import 'style.dart';
import 'surface.dart';
import 'offline_translation.dart';
import '../core/home_feed.dart';
import 'home_order.dart';
import 'settings_choice.dart';
import '../playback/cache_policy.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    required this.browse,
    this.interfacePreferences,
    this.homeFeed,
  });
  final InterfacePreferences? interfacePreferences;
  final HomeFeed? homeFeed;
  final AppStore store;
  final BrowseRepository browse;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool testingConnection = false;
  String? connectionResult;
  Future<void> testConnection() async {
    if (testingConnection || widget.browse.api.backgroundWork.paused) return;
    setState(() {
      testingConnection = true;
      connectionResult = null;
    });
    try {
      await widget.browse.api.testConnection();
      if (mounted) {
        setState(
          () => connectionResult =
              '连接正常 · ${widget.browse.api.connection.latencyMs ?? 0} ms',
        );
      }
    } catch (e) {
      if (mounted) setState(() => connectionResult = safeError(e));
    } finally {
      if (mounted) setState(() => testingConnection = false);
    }
  }

  late final preferences =
      widget.interfacePreferences ?? InterfacePreferences(widget.store.prefs);
  @override
  void dispose() {
    if (widget.interfacePreferences == null) preferences.dispose();
    super.dispose();
  }

  String? notice;
  bool clearing = false;
  Future<void> change(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => notice = null);
    } catch (e) {
      if (mounted) setState(() => notice = safeError(e));
    }
  }

  Future<void> clear(String name, Future<void> Function() action) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text('清理$name？'),
        content: const Text('清理后需要重新加载对应内容。账户、观看进度和播放偏好会保留。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清理'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => clearing = true);
    try {
      await action();
      if (mounted) {
        setState(() => notice = widget.browse.cache.warning ?? '$name已清理');
      }
    } catch (e) {
      if (mounted) setState(() => notice = safeError(e));
    } finally {
      if (mounted) setState(() => clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.store,
      widget.browse.preferences,
      preferences,
      imageCacheBudget,
      actorCacheBudget,
      landscapeCacheBudget,
      widget.browse.api.connection,
      widget.browse.api.backgroundWork,
    ]),
    builder: (context, _) => PageList(
      storageKey: const PageStorageKey('settings-page'),
      bottom: browseBottomSpace(context),
      header: const SectionHeading('设置'),
      children: [
        if (notice != null)
          Padding(padding: const EdgeInsets.all(20), child: Text(notice!)),
        if (widget.homeFeed != null)
          SettingsGroup(
            title: '首页',
            children: [
              SettingsAction(
                id: 'home-section-order',
                title: '首页分区排序',
                actionLabel: '调整分区顺序',
                reducedMotion: preferences.reducedMotion,
                subtitle: '上下拖动最新分区；继续观看保持原位',
                icon: CupertinoIcons.sort_down,
                onAction: () => showSurface<void>(
                  context,
                  (_) => HomeOrderPage(feed: widget.homeFeed!),
                ),
              ),
            ],
          ),
        SettingsGroup(
          title: '服务器连接',
          footer: '检测 Emby 连接与登录权限，不读取影片。播放期间暂停后台巡检。',
          children: [
            SettingsAction(
              id: 'test-emby-connection',
              title: '测试 Emby 连接',
              actionLabel: '开始检测',
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.wifi,
              subtitle: testingConnection
                  ? '正在测试…'
                  : widget.browse.api.connection.hasProblem
                  ? '${widget.browse.api.connection.label} · ${connectionResult ?? widget.browse.api.connection.detail ?? "请检查网络"}'
                  : connectionResult?.startsWith('连接正常') == true
                  ? connectionResult
                  : widget.browse.api.connection.label,
              enabled:
                  !testingConnection &&
                  !widget.browse.api.backgroundWork.paused,
              onAction: testConnection,
            ),
          ],
        ),
        SettingsGroup(
          title: '外观',
          children: [
            SettingsChoice<PosterActionMode>(
              id: 'poster-actions-setting',
              title: '海报操作方式',
              value: preferences.posterActionMode,
              choices: {
                for (final mode in PosterActionMode.values) mode: mode.label,
              },
              subtitle: preferences.posterActionMode.label,
              icon: CupertinoIcons.hand_point_right,
              reducedMotion: preferences.reducedMotion,
              onChanged: (mode) =>
                  change(() => preferences.setPosterActionMode(mode)),
            ),
            if (!phoneLayout(context))
              SettingsChoice<LibraryDisplay>(
                id: 'library-display-setting',
                title: '媒体库展示',
                value: preferences.libraryDisplay,
                choices: {
                  for (final value in LibraryDisplay.values) value: value.label,
                },
                reducedMotion: preferences.reducedMotion,
                icon: CupertinoIcons.square_grid_2x2,
                subtitle:
                    '${preferences.libraryDisplay.label} · ${preferences.libraryDisplay.description}',
                onChanged: (value) =>
                    change(() => preferences.setLibraryDisplay(value)),
              ),
            SettingsChoice<VisualStyle>(
              id: 'visual-style-setting',
              title: '全局效果',
              value: widget.store.visualStyle,
              choices: {
                for (final value in VisualStyle.values) value: value.label,
              },
              icon: CupertinoIcons.drop,
              subtitle: widget.store.visualStyle.label,
              reducedMotion: preferences.reducedMotion,
              onChanged: (value) =>
                  change(() => widget.store.setVisualStyle(value)),
            ),
            SettingsChoice<AppAccent>(
              id: 'accent-setting',
              title: '主题色',
              value: widget.store.accent,
              choices: {
                for (final value in AppAccent.available) value: value.label,
              },
              reducedMotion: preferences.reducedMotion,
              choiceIcon: (value) => Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: value.swatch,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: secondaryColor(context).withValues(alpha: .35),
                  ),
                ),
              ),
              icon: CupertinoIcons.paintbrush,
              subtitle: widget.store.accent.label,
              onChanged: (value) => change(() => widget.store.setAccent(value)),
            ),
            SettingsRow(
              '减少动画',
              onTap: () => change(
                () => preferences.setReducedMotion(!preferences.reducedMotion),
              ),
              icon: CupertinoIcons.sparkles,
              subtitle: '底部选中标记直接切换；也遵循系统的减少动态效果设置',
              trailing: CupertinoSwitch(
                activeTrackColor: accentColor(context),
                value: preferences.reducedMotion,
                onChanged: (value) =>
                    change(() => preferences.setReducedMotion(value)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoSlidingSegmentedControl<ThemeMode>(
                  groupValue: widget.store.theme,
                  children: const {
                    ThemeMode.system: Text('系统'),
                    ThemeMode.light: Text('浅色'),
                    ThemeMode.dark: Text('深色'),
                  },
                  onValueChanged: (value) {
                    if (value != null) {
                      change(() => widget.store.setTheme(value));
                    }
                  },
                ),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: '播放',
          children: [
            SettingsRow(
              '原生 HDR（测试）',
              icon: CupertinoIcons.sun_max,
              subtitle:
                  '下次播放生效；仅对支持的屏幕及普通 HDR10／HLG 影片尝试，条件不足时使用兼容显示；杜比和原盘保持现有输出',
              onTap: () => change(
                () => widget.store.setNativeHdr(!widget.store.nativeHdr),
              ),
              trailing: CupertinoSwitch(
                value: widget.store.nativeHdr,
                activeTrackColor: accentColor(context),
                onChanged: (value) =>
                    change(() => widget.store.setNativeHdr(value)),
              ),
            ),
            SettingsRow(
              '音量均衡（测试）',
              icon: CupertinoIcons.waveform,
              subtitle: widget.store.audioBalanceEnabled
                  ? '下次播放使用${widget.store.audioBalance.label}；影片中可在三点菜单调整，音频直通时不启用'
                  : '默认保留原始声音；开启后可在播放器三点菜单调整均衡强度，下次播放生效',
              onTap: () => change(
                () => widget.store.setAudioBalanceEnabled(
                  !widget.store.audioBalanceEnabled,
                ),
              ),
              trailing: CupertinoSwitch(
                value: widget.store.audioBalanceEnabled,
                activeTrackColor: accentColor(context),
                onChanged: (value) =>
                    change(() => widget.store.setAudioBalanceEnabled(value)),
              ),
            ),
            SettingsRow(
              '允许流量播放',
              icon: CupertinoIcons.antenna_radiowaves_left_right,
              subtitle: '关闭时，使用移动数据播放前先询问；本次确认不会打开此开关',
              onTap: () => change(
                () => widget.store.setAllowMobilePlayback(
                  !widget.store.allowMobilePlayback,
                ),
              ),
              trailing: CupertinoSwitch(
                value: widget.store.allowMobilePlayback,
                activeTrackColor: accentColor(context),
                onChanged: (value) =>
                    change(() => widget.store.setAllowMobilePlayback(value)),
              ),
            ),
            SettingsRow(
              '自动播放下一集',
              onTap: () => change(
                () => widget.store.setAutoNext(!widget.store.autoNext),
              ),
              subtitle: '本集最后 5 秒提示，可取消；播完后衔接下一集，不预取媒体',
              icon: CupertinoIcons.forward_end,
              trailing: CupertinoSwitch(
                value: widget.store.autoNext,
                activeTrackColor: accentColor(context),
                onChanged: (value) =>
                    change(() => widget.store.setAutoNext(value)),
              ),
            ),
            SettingsRow(
              '下一集准备',
              key: const Key('prepare-next'),
              icon: CupertinoIcons.forward_end,
              subtitle: '提前准备下一集资料；关闭后沿用原换集方式',
              onTap: () => change(
                () => preferences.setPrepareNext(!preferences.prepareNext),
              ),
              trailing: CupertinoSwitch(
                activeTrackColor: accentColor(context),
                value: preferences.prepareNext,
                onChanged: (value) =>
                    change(() => preferences.setPrepareNext(value)),
              ),
            ),
            SettingsRow(
              '自动选择字幕',
              onTap: () => change(
                () =>
                    widget.store.setAutoSubtitles(!widget.store.autoSubtitles),
              ),
              icon: CupertinoIcons.captions_bubble,
              subtitle: '优先简体中文；手动选择或关闭的记忆优先',
              trailing: CupertinoSwitch(
                activeTrackColor: accentColor(context),
                value: widget.store.autoSubtitles,
                onChanged: (value) =>
                    change(() => widget.store.setAutoSubtitles(value)),
              ),
            ),
            const SettingsRow(
              '默认音轨',
              icon: CupertinoIcons.music_note,
              subtitle: '沿用影片默认音轨；同片手动选择的记忆优先',
            ),
            SettingsChoice<int>(
              id: 'hold-speed',
              title: '长按播放倍速',
              value: widget.store.holdSpeed,
              choices: const {3: '3 倍速', 2: '2 倍速'},
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.forward_fill,
              subtitle: '${widget.store.holdSpeed} 倍速 · 松手恢复原速度',
              onChanged: (value) =>
                  change(() => widget.store.setHoldSpeed(value)),
            ),
          ],
        ),
        OfflineTranslationGroup(
          service: widget.store.translation,
          reducedMotion: preferences.reducedMotion,
        ),
        SettingsGroup(
          title: '缓存与加载',
          footer: '播放和后台期间暂停自动同步；图片共用加载限制。各类缓存可分别清理，账户、观看进度和播放偏好会保留。',
          children: [
            SettingsChoice<int>(
              id: 'actor-cache-limit',
              title: '演员图片缓存上限',
              icon: CupertinoIcons.person_2,
              value: preferences.actorCacheGB,
              choices: const {1: '1 GB', 3: '3 GB', 5: '5 GB'},
              reducedMotion: preferences.reducedMotion,
              subtitle:
                  '${preferences.actorCacheGB} GB · 独立存放；加载遵守海报的速度、请求上限和暂停规则',
              onChanged: (value) => change(() async {
                await preferences.setActorCacheGB(value);
                await actorCacheBudget.setLimit(value * imageGB);
              }),
            ),
            SettingsChoice<int>(
              id: 'cache-limit',
              title: '图片缓存上限',
              value: preferences.cacheGB,
              choices: const {1: '1 GB', 5: '5 GB', 10: '10 GB'},
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.archivebox,
              subtitle: '${preferences.cacheGB} GB · 海报和大图分开存放，共用容量上限',
              onChanged: (value) => change(() async {
                await preferences.setCacheGB(value);
                await imageCacheBudget.setLimit(value * imageGB);
              }),
            ),
            SettingsChoice<int>(
              id: 'landscape-cache-limit',
              title: '横版海报缓存上限',
              value: preferences.landscapeCacheGB,
              choices: const {1: '1 GB', 3: '3 GB', 5: '5 GB'},
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.rectangle,
              subtitle:
                  '${preferences.landscapeCacheGB} GB · 继续观看横图独立存放，相同图片优先复用本机数据',
              onChanged: (value) => change(() async {
                await preferences.setLandscapeCacheGB(value);
                await landscapeCacheBudget.setLimit(value * imageGB);
              }),
            ),
            SettingsChoice<int>(
              id: 'playback-cache-limit',
              title: '视频缓存上限',
              value: widget.store.playbackCacheGB,
              choices: playbackCacheChoices,
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.film,
              subtitle: widget.store.playbackCacheGB == 0
                  ? '不缓存 · 仅临时缓冲，退出视频后清理'
                  : '${playbackCacheChoices[widget.store.playbackCacheGB]} · 退出后保留，空间不足时先清理较久未使用的视频片段；与图片缓存独立',
              onChanged: (value) =>
                  change(() => widget.store.setPlaybackCacheGB(value)),
            ),
            SettingsChoice<int>(
              id: 'image-auto-clean',
              reducedMotion: preferences.reducedMotion,
              title: '图片自动清理',
              subtitle:
                  '${InterfacePreferences.imageAutoCleanChoices[preferences.imageAutoCleanDays]} · 周期仅用于未使用的详情大图，海报优先保留；容量满时仍先清理大图',
              icon: CupertinoIcons.calendar,
              value: preferences.imageAutoCleanDays,
              choices: InterfacePreferences.imageAutoCleanChoices,
              enabled: !clearing,
              onChanged: (value) => change(() async {
                await preferences.setImageAutoCleanDays(value);
                await imageCacheBudget.setAutoCleanDays(value);
              }),
            ),
            SettingsChoice<ImageLoadSpeed>(
              id: 'image-speed',
              title: '图片加载速度',
              value: preferences.imageLoadSpeed,
              choices: {
                for (final value in ImageLoadSpeed.values)
                  value: '${value.label}（${value.intervalLabel}）',
              },
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.photo,
              subtitle:
                  '${preferences.imageLoadSpeed.label} · 请求开始至少间隔 ${preferences.imageLoadSpeed.intervalLabel}',
              onChanged: (value) => change(() async {
                await preferences.setImageLoadSpeed(value);
                setImageLoadSpeed(value);
              }),
            ),
            SettingsChoice<int>(
              id: 'image-limit',
              title: '图片请求上限',
              value: preferences.imageRequestLimit,
              choices: {
                for (final value in InterfacePreferences.imageRequestLimits)
                  value: value == 0 ? '无上限' : '每秒最多 $value 张',
              },
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.timer,
              subtitle: preferences.imageRequestLimit == 0
                  ? '无每秒数量上限 · 保留加载间隔，同时最多 2 张'
                  : '每秒最多 ${preferences.imageRequestLimit} 张 · 同时最多 2 张',
              onChanged: (value) => change(() async {
                await preferences.setImageRequestLimit(value);
                setImageRequestLimit(value);
              }),
            ),
            SettingsChoice<int>(
              id: 'refresh-interval',
              title: '自动刷新间隔',
              value: widget.browse.preferences.minutes,
              choices: const {5: '5 分钟', 15: '15 分钟', 30: '30 分钟'},
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.arrow_2_circlepath,
              subtitle: '每 ${widget.browse.preferences.minutes} 分钟',
              onChanged: (value) =>
                  change(() => widget.browse.preferences.setMinutes(value)),
            ),
            const SettingsRow(
              '浏览资料缓存',
              icon: CupertinoIcons.square_stack_3d_up,
              subtitle: '最多 8 MB；再次进入页面时优先显示本机内容',
            ),
            SettingsAction(
              id: 'clear-actor-cache',
              title: '演员图片缓存',
              actionLabel: '清理演员图片缓存',
              icon: CupertinoIcons.person_crop_rectangle,
              reducedMotion: preferences.reducedMotion,
              enabled: !clearing,
              subtitle: '只清理演员图片，保留其他图片缓存',
              onAction: () => clear('演员图片缓存', actorCache.emptyCache),
            ),
            SettingsAction(
              id: 'clear-landscape-cache',
              title: '横版海报缓存',
              actionLabel: '清理横版海报缓存',
              icon: CupertinoIcons.rectangle,
              reducedMotion: preferences.reducedMotion,
              enabled: !clearing,
              subtitle: '只清理继续观看横图，保留海报墙、详情大图和演员图片',
              onAction: () => clear('横版海报缓存', landscapeCache.emptyCache),
            ),
            SettingsAction(
              id: 'clear-poster-cache',
              title: '海报墙缓存',
              actionLabel: '清理海报墙缓存',
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.photo,
              subtitle: '优先保留；清理大图后仍不足时，按最久未使用回收，点击清理',
              enabled: !clearing,
              onAction: () => clear('海报墙缓存', posterCache.emptyCache),
            ),
            SettingsAction(
              id: 'clear-artwork-cache',
              title: '详情大图缓存',
              actionLabel: '清理详情大图缓存',
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.photo_on_rectangle,
              subtitle: '容量满时优先清理最久未使用的大图；定时清理由上方选项决定，点击手动清理',
              enabled: !clearing,
              onAction: () => clear('详情大图缓存', artworkCache.emptyCache),
            ),
            SettingsAction(
              id: 'clear-browse-cache',
              title: '清理浏览资料缓存',
              actionLabel: '清理浏览资料缓存',
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.trash,
              subtitle: '保留账户、观看进度和所有播放偏好',
              enabled: !clearing,
              onAction: () => clear('浏览资料缓存', widget.browse.cache.clear),
            ),
            SettingsAction(
              id: 'clear-playback-cache',
              title: '清理视频缓存',
              actionLabel: '清理视频缓存',
              icon: CupertinoIcons.trash,
              reducedMotion: preferences.reducedMotion,
              enabled: !clearing,
              subtitle:
                  widget.store.videoCache.warning ?? '只清理视频片段，保留海报、大图、账户和观看进度',
              onAction: () => clear('视频缓存', widget.store.videoCache.clear),
            ),
            if (widget.browse.cache.warning != null)
              SettingsRow('缓存状态', subtitle: widget.browse.cache.warning),
            if (imageCacheBudget.warning != null)
              SettingsRow('图片缓存状态', subtitle: imageCacheBudget.warning),
            if (actorCacheBudget.warning != null)
              SettingsRow('演员缓存状态', subtitle: actorCacheBudget.warning),
            if (landscapeCacheBudget.warning != null)
              SettingsRow('横版海报缓存状态', subtitle: landscapeCacheBudget.warning),
            if (widget.store.images.warning != null)
              SettingsRow('图片清理状态', subtitle: widget.store.images.warning),
          ],
        ),
        SettingsGroup(
          title: '应用',
          children: [
            SettingsAction(
              id: 'logs-setting',
              title: '日志记录',
              actionLabel: '查看日志',
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.doc_text,
              onAction: () => showSurface<void>(
                context,
                (_) => LogsPage(log: widget.store.log),
              ),
            ),
            SettingsAction(
              id: 'licenses-setting',
              title: '开源许可',
              actionLabel: '查看开源许可',
              reducedMotion: preferences.reducedMotion,
              icon: CupertinoIcons.chevron_left_slash_chevron_right,
              onAction: () =>
                  showSurface<void>(context, (_) => const LicensesPage()),
            ),
          ],
        ),
      ],
    ),
  );
}
