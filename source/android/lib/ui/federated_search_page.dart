import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Scaffold, AppBar;
import '../core/accounts.dart';
import '../core/emby.dart';
import '../core/federated_search.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'library_layout.dart';
import '../core/interface_preferences.dart';
import 'style.dart';

class FederatedSearchPage extends StatefulWidget {
  const FederatedSearchPage({
    super.key,
    required this.api,
    required this.store,
    required this.onOpen,
    this.initialQuery = '',
  });
  final EmbyClient api;
  final AppStore store;
  final String initialQuery;
  final Future<void> Function(SavedAccount, MediaItem) onOpen;
  @override
  State<FederatedSearchPage> createState() => _FederatedSearchPageState();
}

class _FederatedSearchPageState extends State<FederatedSearchPage>
    with WidgetsBindingObserver {
  late final text = TextEditingController(text: widget.initialQuery);
  FederatedSearch? search;
  Timer? debounce;
  bool opening = false, foreground = true;
  String? openingError;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.api.backgroundWork.addListener(workChanged);
    unawaited(initialize());
  }

  Future<void> initialize() async {
    await widget.store.accounts.load(widget.store.deviceId);
    if (!mounted) return;
    final accounts = [...widget.store.accounts.accounts];
    final current = widget.api.session;
    if (current != null && !accounts.any((a) => a.id == accountKey(current))) {
      accounts.insert(0, SavedAccount(current));
    }
    search = FederatedSearch(widget.api, accounts)..addListener(changed);
    setState(() {});
    submit();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void workChanged() {
    if (widget.api.backgroundWork.paused) {
      debounce?.cancel();
      search?.cancel();
    } else if (foreground) {
      submit();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      debounce?.cancel();
      search?.cancel();
    } else {
      submit();
    }
  }

  void submit() {
    debounce?.cancel();
    if (!foreground || widget.api.backgroundWork.paused || opening) return;
    unawaited(search?.search(text.text));
  }

  Future<void> open(SearchSource source, MediaItem item) async {
    if (opening) return;
    setState(() {
      opening = true;
      openingError = null;
    });
    search?.cancel();
    try {
      await widget.onOpen(source.account, item);
    } catch (error) {
      if (mounted) setState(() => openingError = safeError(error));
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    search?.dispose();
    text.dispose();
    widget.api.backgroundWork.removeListener(workChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('聚合搜索')),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: CupertinoSearchTextField(
              key: const Key('federated-search'),
              controller: text,
              placeholder: '搜索全部已保存账号的影视',
              onChanged: (_) {
                search?.cancel();
                debounce?.cancel();
                debounce = Timer(const Duration(milliseconds: 350), submit);
              },
              onSubmitted: (_) => submit(),
              onSuffixTap: () {
                text.clear();
                submit();
              },
            ),
          ),
          if (opening) const CupertinoActivityIndicator(),
          if (openingError != null) Text(openingError!),
          Expanded(
            child: search == null
                ? const Center(child: CupertinoActivityIndicator())
                : LayoutBuilder(
                    builder: (context, constraints) => CustomScrollView(
                      slivers: [
                        if (text.text.trim().isEmpty)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text('输入片名，同时搜索不同服务器和账号。结果按来源展示。'),
                            ),
                          ),
                        for (final source in search!.sources)
                          ...sourceSlivers(
                            context,
                            source,
                            constraints.maxWidth,
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
  List<Widget> sourceSlivers(
    BuildContext context,
    SearchSource source,
    double width,
  ) {
    final session = source.account.session;
    final items = widget.store.homeOrder.visible(session, source.items);
    final metrics = LibraryGridMetrics(
      width,
      MediaQuery.textScalerOf(context).scale(14) / 14,
      LibraryDisplay.posters,
      phone: phoneLayout(context),
    );
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.store.accountDisplays.read(session).name(session)} · ${accountServer(session)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (source.busy)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: CupertinoActivityIndicator(),
                ),
              if (source.error != null)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: opening || source.busy || source.account.needsLogin
                      ? null
                      : () => search!.retry(source),
                  child: Text(
                    '${source.error}${source.account.needsLogin ? '' : ' · 点击重试'}',
                  ),
                ),
              if (!source.busy &&
                  source.error == null &&
                  items.isEmpty &&
                  search!.query.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('该来源没有匹配结果'),
                ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.only(
          left: metrics.inset,
          right: metrics.rightInset,
        ),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: metrics.columns,
            mainAxisExtent: metrics.rowHeight,
            crossAxisSpacing: metrics.spacing,
            mainAxisSpacing: 12,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => LibraryPosterCard(
              key: ValueKey('${source.account.id}:${items[i].id}'),
              item: items[i],
              api: source.api,
              active:
                  foreground && !opening && !widget.api.backgroundWork.paused,
              onTap: () => open(source, items[i]),
            ),
            childCount: items.length,
          ),
        ),
      ),
      if (source.more)
        SliverToBoxAdapter(
          child: CupertinoButton(
            onPressed: source.busy || opening
                ? null
                : () => search!.more(source),
            child: const Text('加载该来源更多结果'),
          ),
        ),
    ];
  }
}
