import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/surface.dart';
import 'danmaku_overlay.dart';
import 'danmaku_preferences.dart';
import 'danmaku_sources.dart';
import 'danmaku_storage.dart';

class DanmakuSettings extends StatefulWidget {
  const DanmakuSettings({
    super.key,
    required this.initial,
    this.status,
    this.controller,
    required this.onChanged,
    this.onImport,
  });
  final DanmakuPreferences initial;
  final ValueNotifier<String>? status;
  final DanmakuOverlayController? controller;
  final ValueChanged<DanmakuPreferences> onChanged;
  final Future<void> Function()? onImport;

  @override
  State<DanmakuSettings> createState() => _DanmakuSettingsState();
}

class _DanmakuSettingsState extends State<DanmakuSettings> {
  late DanmakuPreferences prefs = widget.initial;
  late final address = TextEditingController(text: prefs.compatible);
  final query = TextEditingController();
  final scroll = ScrollController();
  DanmakuTrack? selected;
  String? error;
  String? cacheStatus;
  bool sources = false;

  void change(DanmakuPreferences value) {
    setState(() => prefs = value);
    widget.onChanged(value);
  }

  void appearance(DanmakuAppearance value) =>
      change(prefs.copyWith(appearance: value));

  @override
  void dispose() {
    address.dispose();
    query.dispose();
    scroll.dispose();
    super.dispose();
  }

  Widget toggle(String title, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(title),
        value: value,
        onChanged: onChanged,
      );

  Widget range(
    String label,
    double min,
    double max,
    int steps,
    double value,
    String formatted,
    ValueChanged<double> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(formatted),
        ],
      ),
      Slider(
        semanticFormatterCallback: (value) =>
            '$label ${value.toStringAsFixed(1)}',
        min: min,
        max: max,
        divisions: steps,
        value: value.clamp(min, max),
        onChanged: onChanged,
      ),
    ],
  );

  List<Widget> appearanceRows() {
    final look = prefs.appearance;
    return [
      toggle('显示弹幕', prefs.enabled, (v) => change(prefs.copyWith(enabled: v))),
      if (widget.controller == null)
        toggle(
          '精选弹幕',
          look.featured,
          (v) => appearance(look.update(featured: v)),
        ),
      Wrap(
        spacing: 8,
        children: [
          FilterChip(
            label: const Text('滚动'),
            selected: look.scroll,
            onSelected: (v) => appearance(look.update(scroll: v)),
          ),
          FilterChip(
            label: const Text('顶部'),
            selected: look.top,
            onSelected: (v) => appearance(look.update(top: v)),
          ),
          FilterChip(
            label: const Text('底部'),
            selected: look.bottom,
            onSelected: (v) => appearance(look.update(bottom: v)),
          ),
        ],
      ),
      range(
        '不透明度',
        .15,
        1,
        17,
        look.opacity,
        '${(look.opacity * 100).round()}%',
        (v) => appearance(look.update(opacity: v)),
      ),
      range(
        '基础字号',
        14,
        40,
        26,
        look.fontSize,
        '${look.fontSize.round()}',
        (v) => appearance(look.update(fontSize: v)),
      ),
      toggle(
        '随播放窗口自动适配字号',
        look.adaptive,
        (v) => appearance(look.update(adaptive: v)),
      ),
      toggle(
        '显示文字背景框',
        look.background,
        (v) => appearance(look.update(background: v)),
      ),
      range(
        '显示区域',
        .2,
        1,
        16,
        look.area,
        '${(look.area * 100).round()}%',
        (v) => appearance(look.update(area: v)),
      ),
      range(
        '弹幕速度',
        .45,
        2.25,
        36,
        9 / look.travel,
        '${(9 / look.travel).toStringAsFixed(2)} 倍',
        (v) => appearance(look.update(travel: 9 / v)),
      ),
      const Text('为常规字幕预留底部空间，底部弹幕在预留区上方显示。'),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () => appearance(
            defaultDanmakuAppearance.update(
              featured: look.featured,
              delay: look.delay,
            ),
          ),
          child: const Text('恢复默认设置'),
        ),
      ),
    ];
  }

  List<Widget> sourceRows() => [
    if (widget.status case final status?)
      ValueListenableBuilder(
        valueListenable: status,
        builder: (_, status, _) => Text(status),
      ),
    toggle(
      '自动在线匹配',
      prefs.automatic,
      (v) => change(prefs.copyWith(automatic: v)),
    ),
    if (widget.controller case final controller?) ...[
      OutlinedButton(
        onPressed: prefs.enabled ? controller.retry : null,
        child: const Text('重新匹配公开弹幕'),
      ),
      ValueListenableBuilder(
        valueListenable: controller.remembered,
        builder: (_, remembered, _) => remembered
            ? TextButton(
                onPressed: controller.forget,
                child: const Text('忘记本集纠错，恢复自动匹配'),
              )
            : const SizedBox.shrink(),
      ),
      ValueListenableBuilder(
        valueListenable: controller.active,
        builder: (_, active, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('本次播放的来源'),
            if (active.isEmpty) const Text('暂无已匹配来源'),
            for (final track in active)
              Text(
                track.label == null
                    ? track.source
                    : '${track.source} · ${track.label}',
              ),
          ],
        ),
      ),
      TextField(
        controller: query,
        maxLength: 320,
        decoration: const InputDecoration(labelText: '搜索片名或粘贴单集链接'),
      ),
      OutlinedButton(
        onPressed: !prefs.enabled
            ? null
            : () {
                FocusScope.of(context).unfocus();
                final value = query.text.trim();
                if (value.isNotEmpty) unawaited(controller.search(value));
              },
        child: const Text('查找在线弹幕'),
      ),
      ValueListenableBuilder(
        valueListenable: controller.candidates,
        builder: (_, candidates, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButton<DanmakuTrack>(
              isExpanded: true,
              hint: const Text('匹配候选'),
              value: candidates.contains(selected) ? selected : null,
              items: [
                for (final track in candidates)
                  DropdownMenuItem(
                    value: track,
                    child: Text(
                      track.label == null
                          ? track.source
                          : '${track.source} · ${track.label}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: candidates.isEmpty
                  ? null
                  : (track) => setState(() => selected = track),
            ),
            OutlinedButton(
              onPressed: prefs.enabled && candidates.contains(selected)
                  ? () => controller.select(selected!)
                  : null,
              child: Text(selected?.link == null ? '使用所选弹幕' : '用所选来源纠正并记住'),
            ),
            TextButton(
              onPressed: prefs.enabled && candidates.contains(selected)
                  ? () => controller.add(selected!)
                  : null,
              child: const Text('追加为本次播放来源'),
            ),
          ],
        ),
      ),
      OutlinedButton(
        onPressed: prefs.enabled && !prefs.hidden.contains('本地 XML')
            ? widget.onImport
            : null,
        child: const Text('加载本地 XML 弹幕…'),
      ),
    ],
    _DanmakuDelay(
      value: prefs.appearance.delay,
      onChanged: (v) => appearance(prefs.appearance.update(delay: v)),
    ),
    const Text('以下开关和偏移按来源记忆，与上面的全局偏移叠加。正值推迟，负值提前。'),
    for (final source in danmakuSourceNames)
      ExpansionTile(
        key: ValueKey('danmaku-source-$source'),
        tilePadding: EdgeInsets.zero,
        title: Text(source),
        subtitle: Text(
          '${prefs.hidden.contains(source) ? '已屏蔽' : '已启用'} · ${prefs.delays[source] ?? 0} 秒',
        ),
        children: [
          toggle(
            '启用来源',
            !prefs.hidden.contains(source),
            (enabled) => change(prefs.configure(source, enabled: enabled)),
          ),
          _DanmakuDelay(
            value: prefs.delays[source] ?? 0,
            onChanged: (seconds) =>
                change(prefs.configure(source, delay: seconds)),
          ),
        ],
      ),
    TextField(
      controller: address,
      maxLength: 2600,
      maxLines: 3,
      keyboardType: TextInputType.multiline,
      decoration: InputDecoration(
        labelText: '自建备用服务（选填，每行一个）',
        errorText: error,
      ),
    ),
    OutlinedButton(
      onPressed: () {
        final value = address.text.trim();
        final entries = value
            .split(RegExp(r'[\r\n]+'))
            .where((line) => line.trim().isNotEmpty)
            .toList();
        final urls = DanmakuSources.compatibleAddresses(value);
        if (entries.length > 5 ||
            entries.any(
              (line) =>
                  line.length > 512 ||
                  DanmakuSources.compatibleAddress(line) == null,
            )) {
          setState(() => error = '最多 5 条地址，使用 HTTPS 或本机回环 HTTP');
        } else {
          setState(() => error = null);
          final normalized = urls.join('\n');
          address.text = normalized;
          change(prefs.copyWith(compatible: normalized));
          FocusScope.of(context).unfocus();
        }
      },
      child: const Text('保存服务地址'),
    ),
    OutlinedButton(
      onPressed: () async {
        final controller = widget.controller;
        if (controller == null) {
          final cleared = await DanmakuStorage.local.clear();
          if (mounted) {
            setState(() => cacheStatus = cleared ? '弹幕缓存已清空' : '暂时无法清空弹幕缓存');
          }
        } else {
          controller.clear();
        }
      },
      child: const Text('清空弹幕缓存'),
    ),
    if (cacheStatus case final status?) Text(status),
    const Text('公开来源包括哔哩哔哩、腾讯视频、爱奇艺和芒果 TV。'),
  ];

  @override
  Widget build(BuildContext context) => SurfacePage(
    title: '弹幕',
    playerMenu: widget.controller != null,
    playerMenuWidth: widget.controller != null ? 360 : null,
    compactPlayerMenu: widget.controller != null,
    child: Material(
      type: MaterialType.transparency,
      child: ListView(
        controller: scroll,
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('弹幕设置'),
                selected: !sources,
                onSelected: (_) => setState(() => sources = false),
              ),
              ChoiceChip(
                label: const Text('弹幕来源'),
                selected: sources,
                onSelected: (_) => setState(() => sources = true),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...sources ? sourceRows() : appearanceRows(),
        ],
      ),
    ),
  );
}

class _DanmakuDelay extends StatefulWidget {
  const _DanmakuDelay({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;
  @override
  State<_DanmakuDelay> createState() => _DanmakuDelayState();
}

class _DanmakuDelayState extends State<_DanmakuDelay> {
  late final input = TextEditingController(text: widget.value.toString());
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void apply(double value) {
    if (!value.isFinite) return;
    final delay = value.clamp(-3600.0, 3600.0);
    input.text = delay.toString();
    widget.onChanged(delay);
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(
        tooltip: '提前 0.5 秒',
        onPressed: () => apply(widget.value - .5),
        icon: const Icon(Icons.remove),
      ),
      Expanded(
        child: TextField(
          controller: input,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          onSubmitted: (value) => apply(double.tryParse(value) ?? widget.value),
          decoration: InputDecoration(
            labelText: '时间偏移（秒）',
            suffixIcon: IconButton(
              tooltip: '应用时间偏移',
              onPressed: () =>
                  apply(double.tryParse(input.text) ?? widget.value),
              icon: const Icon(Icons.check),
            ),
          ),
        ),
      ),
      IconButton(
        tooltip: '推迟 0.5 秒',
        onPressed: () => apply(widget.value + .5),
        icon: const Icon(Icons.add),
      ),
    ],
  );
}
