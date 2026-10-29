import 'home_visibility.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/accounts.dart';
import '../core/emby.dart';
import '../core/models.dart';
import '../core/personal_library.dart';
import 'library.dart';
import 'library_layout.dart';
import '../core/interface_preferences.dart';
import 'style.dart';
import '../core/personal_sync.dart';
import 'poster_actions.dart';

class SaveMediaButtons extends StatefulWidget {
  const SaveMediaButtons({
    super.key,
    required this.library,
    required this.account,
    required this.item,
    this.sync,
    this.onChanged,
  });
  final PersonalLibrary library;
  final Session account;
  final MediaItem item;
  final PersonalSync? sync;
  final VoidCallback? onChanged;
  @override
  State<SaveMediaButtons> createState() => _SaveMediaButtonsState();
}

class _SaveMediaButtonsState extends State<SaveMediaButtons> {
  bool busy = false;
  String? error;
  Future<void> toggle(SavedList list, bool selected) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (list == SavedList.favorites && widget.sync != null) {
        await widget.sync!.setFavorite(widget.item, !selected);
      } else {
        await widget.library.setSaved(
          widget.account,
          list,
          widget.item,
          !selected,
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.library,
      if (widget.sync != null) widget.sync!,
    ]),
    builder: (context, _) {
      try {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                for (final list in SavedList.values)
                  Builder(
                    builder: (context) {
                      final selected =
                          list == SavedList.favorites && widget.sync != null
                          ? widget.sync!.favorite(widget.item)
                          : widget.library.contains(
                              widget.account,
                              list,
                              widget.item.id,
                            );
                      return CupertinoButton(
                        key: ValueKey('save-${list.name}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        onPressed: busy || widget.sync?.busy == true
                            ? null
                            : () => toggle(list, selected),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              list == SavedList.watchlist
                                  ? (selected
                                        ? CupertinoIcons.bookmark_fill
                                        : CupertinoIcons.bookmark)
                                  : (selected
                                        ? CupertinoIcons.heart_fill
                                        : CupertinoIcons.heart),
                              size: 19,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              selected
                                  ? (list == SavedList.watchlist
                                        ? '已加入想看'
                                        : '已收藏')
                                  : list.label,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                if (widget.sync != null)
                  PersonalActionsButton(
                    item: widget.item,
                    onChanged: widget.onChanged,
                  ),
              ],
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        );
      } catch (e) {
        return Text(safeError(e));
      }
    },
  );
}

class SavedMediaPage extends StatelessWidget {
  const SavedMediaPage({
    super.key,
    required this.library,
    required this.account,
    required this.api,
    required this.list,
    required this.onItem,
  });
  final PersonalLibrary library;
  final Session account;
  final EmbyClient api;
  final SavedList list;
  final Future<void> Function(MediaItem) onItem;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(list.label)),
    body: ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        if (api.session == null ||
            accountKey(api.session!) != accountKey(account)) {
          return const Center(child: Text('账号已切换，请返回后重新打开'));
        }
        try {
          final items = HomeVisibilityScope.visible(
            context,
            account,
            library.items(account, list),
          );
          return Column(
            children: [
              VisibilityStatus(account: account),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '${accountName(account)} · ${accountServer(account)}\n本机保存 · ${items.length} 项',
                  style: TextStyle(color: secondaryColor(context)),
                  textAlign: TextAlign.center,
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          '还没有${list.label}的影片\n在详情页点“${list.label}”即可加入',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : phoneLayout(context)
                    ? LayoutBuilder(
                        builder: (context, bounds) {
                          final metrics = LibraryGridMetrics(
                            bounds.maxWidth,
                            MediaQuery.textScalerOf(context).scale(14) / 14,
                            LibraryDisplay.posters,
                            phone: true,
                          );
                          return GridView.builder(
                            padding: EdgeInsets.fromLTRB(
                              metrics.inset,
                              8,
                              metrics.rightInset,
                              32,
                            ),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: metrics.columns,
                                  mainAxisExtent: metrics.rowHeight,
                                  mainAxisSpacing: metrics.spacing,
                                  crossAxisSpacing: metrics.spacing,
                                ),
                            itemCount: items.length,
                            itemBuilder: (context, index) => LibraryPosterCard(
                              item: items[index],
                              api: api,
                              onTap: () => onItem(items[index]),
                              active: true,
                            ),
                          );
                        },
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 18),
                        itemBuilder: (context, index) => Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 140,
                                child: MediaCard(
                                  item: items[index],
                                  api: api,
                                  onTap: () => onItem(items[index]),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '移出${list.label}',
                              icon: const Icon(CupertinoIcons.minus_circle),
                              onPressed: () async {
                                try {
                                  await library.setSaved(
                                    account,
                                    list,
                                    items[index],
                                    false,
                                  );
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(safeError(e))),
                                    );
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          );
        } catch (e) {
          return Center(child: Text(safeError(e)));
        }
      },
    ),
  );
}
