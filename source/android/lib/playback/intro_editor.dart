import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/personal_library.dart';
import '../ui/style.dart';
import '../ui/surface.dart';
import 'controls.dart';
import 'session.dart';

class IntroEditor extends StatefulWidget {
  const IntroEditor({super.key, required this.session});
  final PlaybackSession session;
  @override
  State<IntroEditor> createState() => _IntroEditorState();
}

class _IntroEditorState extends State<IntroEditor> {
  final start = TextEditingController(), end = TextEditingController();
  final credits = TextEditingController();
  late final MediaItem item;
  late final List<SkipScope> scopes;
  late SkipScope scope;
  bool busy = false,
      enabled = true,
      introEnabled = true,
      creditsEnabled = false;
  bool autoIntro = false, autoCredits = false, hasSaved = false;
  bool editIntro = false, editCredits = false;
  String? error;
  static String time(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
  static Duration? parse(String text) {
    final match = RegExp(r'^(\d{1,4}):([0-5]\d)$').firstMatch(text.trim());
    if (match == null) return null;
    return Duration(
      minutes: int.parse(match[1]!),
      seconds: int.parse(match[2]!),
    );
  }

  String scopeLabel(SkipScope value) => switch (value) {
    SkipScope.item => item.type == 'Episode' ? '本集' : '当前影片',
    SkipScope.season => '本季',
    SkipScope.series => '整剧',
  };

  @override
  void initState() {
    super.initState();
    item = widget.session.currentMetadata;
    scopes = SkipScope.values
        .where((s) => PersonalLibrary.skipScopeKey(item, s) != null)
        .toList();
    scope = scopes.contains(SkipScope.season)
        ? SkipScope.season
        : SkipScope.item;
    try {
      final saved = widget.session.store.personal.resolveSkipRule(
        widget.session.account,
        item,
      );
      if (saved != null && scopes.contains(saved.scope)) scope = saved.scope;
      load(scope);
    } catch (e) {
      error = safeError(e);
    }
  }

  void load(SkipScope value) {
    final saved = widget.session.store.personal.skipRuleAt(
      widget.session.account,
      item,
      value,
    );
    final rule = saved?.rule;
    scope = value;
    hasSaved = saved != null;
    editIntro = editCredits = false;
    enabled = rule?.enabled ?? true;
    introEnabled = rule == null || rule.intro != null;
    creditsEnabled = rule?.creditsRemaining != null;
    autoIntro = rule?.autoIntro ?? false;
    autoCredits = rule?.autoCredits ?? false;
    start.text = time(rule?.intro?.start ?? Duration.zero);
    end.text = time(rule?.intro?.end ?? const Duration(seconds: 90));
    credits.text = time(rule?.creditsRemaining ?? const Duration(seconds: 90));
    error = null;
  }

  @override
  void dispose() {
    start.dispose();
    end.dispose();
    credits.dispose();
    super.dispose();
  }

  Future<void> save({bool remove = false}) async {
    final session = widget.session;
    if (busy ||
        session.closed ||
        session.api.session != session.account ||
        session.currentMetadata.id != item.id) {
      return;
    }
    final a = parse(start.text), b = parse(end.text), c = parse(credits.text);
    if (!remove &&
        ((introEnabled && (a == null || b == null)) ||
            (creditsEnabled && c == null))) {
      setState(() => error = '请输入“分:秒”，例如 1:30');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await session.store.personal.setSkipRule(
        session.account,
        item,
        scope,
        remove
            ? null
            : SkipRule(
                enabled: enabled,
                intro: introEnabled ? IntroRange(a!, b!) : null,
                creditsRemaining: creditsEnabled ? c : null,
                autoIntro: introEnabled && autoIntro,
                autoCredits: creditsEnabled && autoCredits,
              ),
        session.backend.snapshot.duration,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget toggle(
    String label,
    bool value,
    ValueChanged<bool> update, {
    String? key,
  }) => Row(
    children: [
      Expanded(child: Text(label)),
      CupertinoSwitch(
        key: key == null ? null : ValueKey(key),
        value: value,
        activeTrackColor: accentColor(context),
        onChanged: busy ? null : (value) => setState(() => update(value)),
      ),
    ],
  );

  Widget field(
    String label,
    TextEditingController controller, {
    bool remaining = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: CupertinoTextField(
              key: ValueKey(
                remaining
                    ? 'skip-credits-remaining'
                    : identical(controller, start)
                    ? 'skip-intro-start'
                    : 'skip-intro-end',
              ),
              controller: controller,
              onChanged: (_) => setState(() {}),
              placeholder: '分:秒',
              enabled: !busy,
              keyboardType: TextInputType.datetime,
              style: TextStyle(color: labelColor(context)),
              padding: const EdgeInsets.all(12),
            ),
          ),
          CupertinoButton(
            onPressed: busy
                ? null
                : () {
                    final value = remaining
                        ? widget.session.backend.snapshot.duration -
                              widget.session.position
                        : widget.session.position;
                    controller.text = time(
                      value < Duration.zero ? Duration.zero : value,
                    );
                  },
            child: Text(
              remaining ? '用当前剩余' : '用当前时间',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
    ],
  );

  Widget mode(String part, bool automatic, ValueChanged<bool> update) => Wrap(
    spacing: 4,
    children: [
      for (final option in [false, true])
        TextButton(
          key: ValueKey('skip-${option ? 'auto' : 'manual'}-$part'),
          onPressed: busy ? null : () => setState(() => update(option)),
          child: Text(
            option ? '自动 · 提示 3 秒' : '手动',
            style: TextStyle(
              color: automatic == option
                  ? accentColor(context)
                  : secondaryColor(context),
            ),
          ),
        ),
    ],
  );

  Widget summary(
    String part,
    String text,
    bool expanded,
    VoidCallback onEdit,
  ) => TextButton(
    key: ValueKey('skip-edit-$part'),
    onPressed: busy ? null : () => setState(onEdit),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(text, style: TextStyle(color: labelColor(context))),
        ),
        Text(
          expanded ? '收起' : '编辑时间',
          style: TextStyle(color: accentColor(context)),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => SurfacePage(
    title: '片头片尾',
    playerMenu: true,
    child: ListView(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      children: [
        Text(item.title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text('应用范围'),
        Wrap(
          spacing: 8,
          children: [
            for (final value in scopes)
              TextButton(
                key: ValueKey('skip-scope-${value.name}'),
                onPressed: busy
                    ? null
                    : () {
                        try {
                          setState(() => load(value));
                        } catch (e) {
                          setState(() => error = safeError(e));
                        }
                      },
                child: Text(
                  scopeLabel(value),
                  style: TextStyle(
                    color: value == scope
                        ? accentColor(context)
                        : labelColor(context),
                  ),
                ),
              ),
          ],
        ),
        if (item.type == 'Episode')
          Text(
            '本集优先于本季，本季优先于整剧。各范围分别保存。',
            style: TextStyle(color: secondaryColor(context), fontSize: 13),
          ),
        toggle('启用此范围规则', enabled, (v) => enabled = v, key: 'skip-enabled'),
        if (!enabled)
          Text(
            '关闭的规则会覆盖更广范围的设置。',
            style: TextStyle(color: secondaryColor(context), fontSize: 13),
          ),
        const SizedBox(height: 12),
        toggle('片头', introEnabled, (v) {
          introEnabled = v;
          if (v) {
            editIntro = true;
            editCredits = false;
          }
        }, key: 'skip-intro-enabled'),
        if (introEnabled) ...[
          summary('intro', '${start.text} – ${end.text}', editIntro, () {
            editIntro = !editIntro;
            if (editIntro) editCredits = false;
          }),
          mode('intro', autoIntro, (v) => autoIntro = v),
          if (editIntro) ...[field('片头开始', start), field('片头结束', end)],
        ],
        const SizedBox(height: 12),
        toggle('片尾', creditsEnabled, (v) {
          creditsEnabled = v;
          if (v) {
            editCredits = true;
            editIntro = false;
          }
        }, key: 'skip-credits-enabled'),
        if (creditsEnabled) ...[
          summary('credits', '剩余 ${credits.text} 开始', editCredits, () {
            editCredits = !editCredits;
            if (editCredits) editIntro = false;
          }),
          mode('credits', autoCredits, (v) => autoCredits = v),
          if (editCredits) field('片尾开始时的剩余时长', credits, remaining: true),
          Text(
            '按每集实际时长计算片尾；跳到结束后沿用连播设置。',
            style: TextStyle(color: secondaryColor(context), fontSize: 13),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          '自动跳过前可选“本次不跳”，跳过后可返回观看。保存不会立即跳转。',
          style: TextStyle(color: secondaryColor(context), fontSize: 13),
        ),
        Text(
          '当前时长 ${clockText(widget.session.backend.snapshot.duration)}',
          style: TextStyle(color: secondaryColor(context)),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 12),
        CupertinoButton.filled(
          onPressed: busy || scopes.isEmpty ? null : save,
          child: Text(busy ? '保存中…' : '保存'),
        ),
        if (hasSaved)
          CupertinoButton(
            onPressed: busy ? null : () => save(remove: true),
            child: Text('移除${scopeLabel(scope)}规则'),
          ),
        if (hasSaved && item.type == 'Episode')
          Text(
            '移除后恢复其他适用范围的规则。',
            style: TextStyle(color: secondaryColor(context), fontSize: 13),
          ),
      ],
    ),
  );
}
