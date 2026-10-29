import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/offline_translation.dart';
import '../core/background_work.dart';
import '../core/models.dart';
import 'style.dart';
import 'surface.dart';
import 'settings_choice.dart';

String translationBytes(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';

class OfflineTranslationGroup extends StatefulWidget {
  const OfflineTranslationGroup({
    super.key,
    required this.service,
    this.reducedMotion = false,
  });
  final OfflineTranslation service;
  final bool reducedMotion;
  @override
  State<OfflineTranslationGroup> createState() =>
      _OfflineTranslationGroupState();
}

class _OfflineTranslationGroupState extends State<OfflineTranslationGroup>
    with WidgetsBindingObserver {
  Timer? poll;
  bool visible = false, foreground = true;
  String? error;
  OfflineTranslation get service => widget.service;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    service.addListener(changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    final resume = next && !visible;
    visible = next;
    schedulePoll();
    if (resume && foreground) {
      scheduleMicrotask(() {
        if (mounted && visible && foreground) unawaited(service.refresh());
      });
    }
  }

  void schedulePoll() {
    if (service.status.busy && visible && foreground) {
      poll ??= Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(service.refresh());
      });
    } else {
      poll?.cancel();
      poll = null;
    }
  }

  void changed() {
    if (!mounted) return;
    schedulePoll();
    if (visible && foreground) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    schedulePoll();
    if (foreground && visible) unawaited(service.refresh());
  }

  Future<void> act(Future<void> Function() action) async {
    setState(() => error = null);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = OfflineTranslation.failure(e));
    }
  }

  Future<void> download() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('下载离线语言包？'),
        content: Text(
          '${OfflineTranslation.modelEstimate}\n\n${OfflineTranslation.downloadNotice}\n\n${service.wifiOnly ? "本次仅使用 Wi-Fi。" : "本次允许使用移动网络，可能产生流量费用。"}',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            key: const Key('translation-confirm-download'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始下载'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await act(service.download);
  }

  Future<void> remove({required bool model}) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(model ? '删除离线语言包？' : '清除译文缓存？'),
        content: Text(
          model
              ? '删除后需要重新下载才能翻译新的简介。已经保存的译文仍可查看。'
              : '清除本机各账号保存的译文，语言包、影片资料和观看进度保留。',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(model ? '删除' : '清除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await act(model ? service.deleteModel : service.clearCache);
    }
  }

  @override
  void dispose() {
    poll?.cancel();
    service.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingsGroup(
    key: const Key('offline-translation-settings'),
    title: '离线翻译',
    footer:
        '${OfflineTranslation.accuracyNotice}\n语言包由本机所有账号共用，译文按账号和影片分别保存。Google ML Kit 可能发送运行统计，不上传简介或译文。',
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  CupertinoIcons.globe,
                  size: 22,
                  color: labelColor(context),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '英语简介 → 中文',
                    style: TextStyle(fontSize: 16, color: labelColor(context)),
                  ),
                ),
                const SizedBox(width: 12),
                CupertinoButton.filled(
                  color: service.status.ready
                      ? CupertinoColors.systemRed.resolveFrom(context)
                      : null,
                  key: Key(
                    service.status.ready
                        ? 'translation-delete'
                        : 'translation-download',
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  minimumSize: const Size(56, 32),
                  borderRadius: BorderRadius.circular(8),
                  onPressed: service.changingModel || service.checking
                      ? null
                      : service.status.ready
                      ? () => remove(model: true)
                      : download,
                  child: Text(
                    service.status.ready
                        ? '删除'
                        : service.status.busy
                        ? '处理中'
                        : service.status.phase == 'pending'
                        ? '继续'
                        : service.status.phase == 'error'
                        ? '重试'
                        : '下载',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (service.checking) ...[
                  const SizedBox(width: 8),
                  const CupertinoActivityIndicator(),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 5),
              child: Text(
                '${service.status.label}\n约 30 MB（官方通用估算）',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: secondaryColor(context),
                ),
              ),
            ),
            if (!service.status.ready &&
                const {
                  'downloading',
                  'waiting_wifi',
                  'waiting_network',
                }.contains(service.status.phase))
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 12),
                child: LinearProgressIndicator(
                  key: const Key('translation-download-progress'),
                  // ML Kit's public download Task exposes completion, not byte
                  // progress. Never turn elapsed time into a fake percentage.
                  value: service.status.phase == 'downloading' ? null : 0,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(3),
                  color: accentColor(context),
                  backgroundColor: accentColor(context).withValues(alpha: .14),
                  semanticsLabel: service.status.label,
                ),
              ),
          ],
        ),
      ),
      const SettingsRow(
        '下载说明',
        subtitle:
            '${OfflineTranslation.modelEstimate}\n${OfflineTranslation.downloadNotice}',
      ),
      SettingsChoice<bool>(
        id: 'translation-network',
        reducedMotion: widget.reducedMotion,
        title: '语言包下载网络',
        subtitle: '${service.wifiOnly ? "仅 Wi-Fi" : "Wi-Fi 或移动网络"} · 仍需手动确认下载',
        value: service.wifiOnly,
        choices: const {true: '仅 Wi-Fi', false: 'Wi-Fi 或移动网络'},
        enabled: !service.changingModel,
        onChanged: (value) => act(() => service.setWifiOnly(value)),
      ),
      SettingsRow(
        '自动翻译英文简介',
        onTap: () => act(() => service.setAutomatic(!service.automatic)),
        subtitle: '默认开启；语言包已下载时翻译当前详情，不自动下载语言包',
        trailing: CupertinoSwitch(
          key: const Key('translation-auto'),
          value: service.automatic,
          onChanged: (value) => act(() => service.setAutomatic(value)),
        ),
      ),
      SettingsAction(
        id: 'translation-clear-cache',
        title: '译文缓存',
        actionLabel: '清除译文缓存',
        reducedMotion: widget.reducedMotion,
        subtitle:
            '${translationBytes(service.cacheBytes)} 文本数据 · 最多 1 MB / 200 条，点击清除',
        icon: CupertinoIcons.doc_text,
        onAction: () => remove(model: false),
      ),
      if (service.status.error != null || error != null)
        SettingsAction(
          id: 'translation-retry-status',
          title: '操作未完成',
          actionLabel: '重新检查状态',
          reducedMotion: widget.reducedMotion,
          subtitle: error ?? service.status.error,
          onAction: () => act(service.refresh),
        ),
    ],
  );
}

class TranslationBadge extends StatelessWidget {
  const TranslationBadge({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: '由 Google Translate 提供的离线机器翻译',
    child: Image.asset(
      Theme.of(context).brightness == Brightness.dark
          ? 'assets/translation/white-short.png'
          : 'assets/translation/color-short.png',
      height: 16,
      excludeFromSemantics: true,
      fit: BoxFit.contain,
    ),
  );
}

class SynopsisTranslation extends StatefulWidget {
  const SynopsisTranslation({
    super.key,
    required this.service,
    required this.account,
    required this.item,
    required this.style,
    required this.currentAccount,
    this.active = true,
    this.backgroundWork,
  });
  final OfflineTranslation service;
  final Session account;
  final MediaItem item;
  final TextStyle style;
  final bool active;
  final bool Function() currentAccount;
  final BackgroundWork? backgroundWork;
  @override
  State<SynopsisTranslation> createState() => _SynopsisTranslationState();
}

class _SynopsisTranslationState extends State<SynopsisTranslation>
    with WidgetsBindingObserver {
  String? translated, error;
  bool original = true, busy = false, attempted = false;
  TranslationRequest? request;
  late int cacheRevision = widget.service.cacheRevision;
  late int modelRevision = widget.service.modelRevision;
  bool get active =>
      mounted &&
      widget.active &&
      widget.currentAccount() &&
      widget.backgroundWork?.paused != true &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
  @override
  void initState() {
    super.initState();
    widget.service.addListener(changed);
    widget.backgroundWork?.addListener(backgroundChanged);
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() {
      if (mounted && widget.service.automatic) {
        unawaited(widget.service.refresh());
      }
    });
  }

  void cancel() {
    request?.cancel();
    request = null;
    busy = false;
  }

  void backgroundChanged() {
    if (!mounted) return;
    if (!active) {
      setState(cancel);
    } else {
      scheduleAuto();
    }
  }

  void changed() {
    if (!mounted) return;
    if (cacheRevision != widget.service.cacheRevision) {
      setState(() {
        cancel();
        translated = null;
        original = true;
        cacheRevision = widget.service.cacheRevision;
      });
    }
    if (modelRevision != widget.service.modelRevision) {
      modelRevision = widget.service.modelRevision;
      setState(cancel);
    }
    scheduleAuto();
  }

  void scheduleAuto() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (active &&
          !attempted &&
          !busy &&
          widget.service.automatic &&
          widget.service.status.ready &&
          !widget.service.changingModel &&
          OfflineTranslation.candidate(widget.item.overview)) {
        unawaited(run(automatic: true));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!active) cancel();
    scheduleAuto();
  }

  @override
  void didUpdateWidget(SynopsisTranslation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.overview != widget.item.overview ||
        oldWidget.account != widget.account) {
      cancel();
      translated = null;
      original = true;
      attempted = false;
      error = null;
    }
    if (!active) cancel();
    scheduleAuto();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (mounted) setState(cancel);
    } else {
      scheduleAuto();
    }
  }

  Future<void> downloadPage() => showSurface<void>(
    context,
    (_) => SurfacePage(
      title: '离线翻译',
      heightRatio: .85,
      child: ListView(
        children: [OfflineTranslationGroup(service: widget.service)],
      ),
    ),
  );
  Future<void> run({bool automatic = false}) async {
    if (busy || !active) return;
    final job = TranslationRequest();
    request = job;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final hit = widget.service.cached(
        widget.account,
        widget.item.id,
        widget.item.overview,
      );
      if (hit == null) {
        await widget.service.refresh();
        if (!mounted || !active || job.cancelled) return;
        if (!widget.service.status.ready || widget.service.changingModel) {
          if (automatic) return;
          setState(() => busy = false);
          final go = await showCupertinoDialog<bool>(
            context: context,
            builder: (context) => CupertinoAlertDialog(
              title: const Text('需要离线语言包'),
              content: const Text('英语简介 → 中文\n预计下载及模型占用各约 30 MB。由你选择是否下载。'),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('前往下载'),
                ),
              ],
            ),
          );
          if (go == true && mounted && widget.currentAccount()) {
            await downloadPage();
          }
          return;
        }
      }
      attempted = true;
      final result =
          hit ??
          await widget.service.translate(
            widget.account,
            widget.item.id,
            widget.item.overview,
            job,
          );
      if (!active || job.cancelled) return;
      setState(() {
        translated = result;
        original = false;
      });
    } on TranslationCancelled {
      // A closed/hidden/changed page owns no result from an earlier request.
    } catch (e) {
      if (active &&
          !job.cancelled &&
          !(automatic && e is PlatformException && e.code == 'not_english')) {
        setState(() => error = OfflineTranslation.failure(e));
      }
    } finally {
      if (mounted && request == job) {
        setState(() {
          busy = false;
          request = null;
        });
      }
    }
  }

  @override
  void dispose() {
    cancel();
    widget.service.removeListener(changed);
    widget.backgroundWork?.removeListener(backgroundChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.item.overview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          !original && translated != null
              ? translated!
              : text.isEmpty
              ? '暂无简介'
              : text,
          style: widget.style,
        ),
        if (OfflineTranslation.candidate(text)) ...[
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              CupertinoButton(
                key: const Key('synopsis-translate'),
                padding: EdgeInsets.zero,
                minimumSize: const Size(44, 36),
                onPressed: busy
                    ? null
                    : () {
                        if (translated != null) {
                          setState(() {
                            attempted = true;
                            original = !original;
                          });
                        } else {
                          unawaited(run());
                        }
                      },
                child: Text(
                  busy
                      ? '翻译中…'
                      : translated == null
                      ? '翻译'
                      : original
                      ? '查看译文'
                      : '查看原文',
                  style: TextStyle(fontSize: 12, color: accentColor(context)),
                ),
              ),
              if (busy) const CupertinoActivityIndicator(radius: 7),
              if (!original && translated != null) const TranslationBadge(),
            ],
          ),
          if (!original && translated != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                OfflineTranslation.accuracyNotice,
                key: const Key('translation-accuracy-notice'),
                style: widget.style.copyWith(
                  fontSize: 12,
                  color: secondaryColor(context),
                ),
              ),
            ),
          if (error != null)
            Text(
              error!,
              style: widget.style.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ],
    );
  }
}
