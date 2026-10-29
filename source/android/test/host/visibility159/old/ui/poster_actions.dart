import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/home_feed.dart';
import '../core/interface_preferences.dart';
import '../core/models.dart';
import '../core/personal_library.dart';
import '../core/personal_sync.dart';
import '../core/version_groups.dart';
import 'anchored_menu.dart';
import 'style.dart';
import 'home_visibility.dart';

class PosterActionsScope extends InheritedWidget {
  const PosterActionsScope({
    super.key,
    required this.sync,
    required this.preferences,
    required this.feed,
    required this.onItem,
    required super.child,
  });
  final PersonalSync sync;
  final InterfacePreferences preferences;
  final HomeFeed feed;
  final Future<void> Function(MediaItem) onItem;
  static PosterActionsScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PosterActionsScope>();
  @override
  bool updateShouldNotify(PosterActionsScope old) =>
      old.sync != sync || old.preferences != preferences;
}

enum _Action {
  open,
  want,
  favorite,
  played,
  unplayed,
  like,
  dislike,
  clearRating,
  hide,
}

List<(_Action, String, IconData, bool)> _actions(
  PosterActionsScope scope,
  MediaItem item,
  bool resume,
  bool detail,
) {
  final sync = scope.sync, saved = sync.latest(item);
  final concrete =
      item is! VersionGroup &&
      const [
        'Movie',
        'Series',
        'Season',
        'Episode',
        'Video',
      ].contains(item.type);
  final playable =
      concrete && const ['Movie', 'Episode', 'Video'].contains(item.type);
  final favorite = concrete && sync.favorite(item);
  final want =
      concrete &&
      sync.library.contains(sync.account, SavedList.watchlist, item.id);
  final rating = sync.ratings.containsKey(item.id)
      ? sync.ratings[item.id]
      : object(saved.data['UserData'])['Likes'];
  return [
    if (!detail)
      (
        _Action.open,
        item is VersionGroup
            ? '选择版本'
            : concrete
            ? '查看详情'
            : '打开',
        CupertinoIcons.info_circle,
        false,
      ),
    if (concrete) ...[
      (
        _Action.favorite,
        favorite ? '取消收藏' : '收藏',
        CupertinoIcons.heart,
        favorite,
      ),
      (_Action.want, want ? '移出想看' : '加入想看', CupertinoIcons.bookmark, want),
    ],
    if (playable) ...[
      (
        _Action.played,
        '标记已看',
        CupertinoIcons.check_mark_circled,
        object(saved.data['UserData'])['Played'] == true,
      ),
      (
        _Action.unplayed,
        '标记未看',
        CupertinoIcons.circle,
        object(saved.data['UserData'])['Played'] == false,
      ),
    ],
    if (concrete) ...[
      (_Action.like, '喜欢', CupertinoIcons.hand_thumbsup, rating == true),
      (_Action.dislike, '不喜欢', CupertinoIcons.hand_thumbsdown, rating == false),
      (_Action.clearRating, '清除喜好', CupertinoIcons.arrow_uturn_left, false),
    ],
    if (resume) (_Action.hide, '移出“继续观看”', CupertinoIcons.minus_circle, false),
  ];
}

double _menuWidth(
  BuildContext context,
  PosterActionsScope scope,
  MediaItem item,
  bool resume,
  bool detail,
) => compactMenuWidth(
  context,
  _actions(scope, item, resume, detail).map((action) => action.$2),
  extra: 51,
);

List<PopupMenuEntry<_Action>> _entries(
  BuildContext context,
  PosterActionsScope scope,
  MediaItem item,
  bool resume,
  bool detail,
) {
  return [
    for (final (action, label, icon, checked) in _actions(
      scope,
      item,
      resume,
      detail,
    ))
      PopupMenuItem(
        value: action,
        key: ValueKey('poster-action-${action.name}-${item.id}'),
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Semantics(
          selected: checked,
          child: Row(
            children: [
              Icon(
                icon,
                size: 17,
                color: checked ? Theme.of(context).colorScheme.primary : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: checked
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
  ];
}

Future<void> _perform(
  BuildContext context,
  PosterActionsScope scope,
  MediaItem item,
  _Action action,
  VoidCallback? changed,
) async {
  try {
    scope.sync.check();
    if (!(HomeVisibilityScope.of(context)?.allows(scope.sync.account, item) ??
        true)) {
      return;
    }
    final sync = scope.sync;
    switch (action) {
      case _Action.open:
        await scope.onItem(item);
      case _Action.favorite:
        await sync.setFavorite(item, !sync.favorite(item));
      case _Action.want:
        await sync.library.setSaved(
          sync.account,
          SavedList.watchlist,
          item,
          !sync.library.contains(sync.account, SavedList.watchlist, item.id),
        );
      case _Action.played:
      case _Action.unplayed:
        final played = action == _Action.played;
        final accepted = await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: Text(played ? '标记已看' : '标记未看'),
            content: Text('“${item.title}”将同步到 Emby，服务器可能重置此片的续播位置。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                isDestructiveAction: !played,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (accepted != true) return;
        await sync.setPlayed(item, played);
      case _Action.like:
        await sync.setRating(item, true);
      case _Action.dislike:
        await sync.setRating(item, false);
      case _Action.clearRating:
        await sync.setRating(item, null);
      case _Action.hide:
        await scope.feed.removeFromResume(item);
    }
    if (context.mounted) changed?.call();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeError(e))));
    }
  }
}

class PersonalActionsButton extends StatelessWidget {
  const PersonalActionsButton({super.key, required this.item, this.onChanged});
  final MediaItem item;
  final VoidCallback? onChanged;
  @override
  Widget build(BuildContext context) {
    final scope = PosterActionsScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: scope.sync,
      builder: (context, _) => AnchoredMenuButton<_Action>(
        id: 'detail-actions-${item.id}',
        label: '影片操作',
        icon: CupertinoIcons.ellipsis,
        iconSize: 20,
        color: accentColor(context),
        enabled: scope.sync.current && !scope.sync.busy,
        menuWidth: _menuWidth(context, scope, item, false, true),
        items: (context) => _entries(context, scope, item, false, true),
        onSelected: (action) =>
            _perform(context, scope, item, action, onChanged),
      ),
    );
  }
}

/// Wraps the entire cover, including badges and the play affordance. Tap and
/// drag retain their existing recognizers; a successful long press consumes
/// only that gesture. Lists place the visible trigger beside the title.
class PosterActionRegion extends StatefulWidget {
  const PosterActionRegion({
    super.key,
    required this.item,
    required this.child,
    this.resume = false,
    this.active = true,
    this.detail = false,
    this.onChanged,
    this.externalMenu = false,
  });
  final MediaItem item;
  final Widget child;
  final bool resume, active, detail;
  final VoidCallback? onChanged;
  final bool externalMenu;
  @override
  State<PosterActionRegion> createState() => _PosterActionRegionState();
}

class _PosterActionRegionState extends State<PosterActionRegion> {
  final controller = AnchoredMenuController();
  @override
  Widget build(BuildContext context) {
    final scope = PosterActionsScope.maybeOf(context);
    if (scope == null) return widget.child;
    return ListenableBuilder(
      listenable: Listenable.merge([
        scope.preferences,
        scope.sync,
        scope.sync.library,
      ]),
      builder: (context, _) {
        final long =
            scope.preferences.posterActionMode == PosterActionMode.longPress;
        final enabled = widget.active && scope.sync.current && !scope.sync.busy;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: enabled && long ? controller.open : null,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              widget.child,
              Positioned(
                bottom: 4,
                right: 0,
                child: IgnorePointer(
                  ignoring: long || widget.externalMenu,
                  child: ExcludeSemantics(
                    excluding: long || widget.externalMenu,
                    child: Opacity(
                      opacity: long || widget.externalMenu ? 0 : 1,
                      child: AnchoredMenuButton<_Action>(
                        controller: controller,
                        id: widget.externalMenu
                            ? 'poster-long-anchor-${widget.item.id}'
                            : 'poster-more-${widget.item.id}',
                        label: '${widget.item.title} 操作',
                        icon: CupertinoIcons.ellipsis,
                        iconSize: 16,
                        color: Colors.white,
                        background: const Color(0x99000000),
                        enabled: enabled,
                        menuWidth: _menuWidth(
                          context,
                          scope,
                          widget.item,
                          widget.resume,
                          widget.detail,
                        ),
                        items: (context) => _entries(
                          context,
                          scope,
                          widget.item,
                          widget.resume,
                          widget.detail,
                        ),
                        onSelected: (action) => _perform(
                          context,
                          scope,
                          widget.item,
                          action,
                          widget.onChanged,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The visible menu sits beside text, leaving artwork, badges and progress clear.
class PosterActionTitle extends StatelessWidget {
  const PosterActionTitle({
    super.key,
    required this.item,
    required this.child,
    this.resume = false,
    this.active = true,
    this.detail = false,
    this.onChanged,
  });
  final MediaItem item;
  final Widget child;
  final bool resume, active, detail;
  final VoidCallback? onChanged;
  @override
  Widget build(BuildContext context) {
    final scope = PosterActionsScope.maybeOf(context);
    if (scope == null) return child;
    return ListenableBuilder(
      listenable: Listenable.merge([scope.preferences, scope.sync]),
      builder: (context, _) {
        if (scope.preferences.posterActionMode == PosterActionMode.longPress) {
          return child;
        }
        return Row(
          children: [
            Expanded(child: child),
            AnchoredMenuButton<_Action>(
              id: 'poster-more-${item.id}',
              label: '${item.title} 操作',
              hitSize: 32,
              icon: CupertinoIcons.ellipsis,
              iconSize: 18,
              color: accentColor(context),
              enabled: active && scope.sync.current && !scope.sync.busy,
              menuWidth: _menuWidth(context, scope, item, resume, detail),
              items: (context) =>
                  _entries(context, scope, item, resume, detail),
              onSelected: (action) =>
                  _perform(context, scope, item, action, onChanged),
            ),
          ],
        );
      },
    );
  }
}
