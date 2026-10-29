import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/home_feed.dart';
import '../core/models.dart';
import 'anchored_menu.dart';

class ResumeMenu extends StatelessWidget {
  const ResumeMenu({
    super.key,
    required this.feed,
    required this.item,
    this.onPoster = false,
  });
  final HomeFeed feed;
  final MediaItem item;
  final bool onPoster;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: feed,
    builder: (context, _) => AnchoredMenuButton<String>(
      id: 'resume-menu-${item.id}',
      label: '${item.title}，更多操作',
      enabled: !feed.removing(item),
      icon: CupertinoIcons.ellipsis,
      iconSize: 16,
      menuWidth: compactMenuWidth(context, ['移出“继续观看”'], extra: 50),
      color: onPoster ? CupertinoColors.white : null,
      background: onPoster ? const Color(0x99000000) : null,
      items: (_) => [
        PopupMenuItem(
          value: 'remove',
          key: ValueKey('resume-remove-${item.id}'),
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: const Row(
            children: [
              Expanded(
                child: Text(
                  '移出“继续观看”',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14),
                ),
              ),
              SizedBox(width: 8),
              Icon(CupertinoIcons.minus_circle, size: 18),
            ],
          ),
        ),
      ],
      onSelected: (_) async {
        final messenger = ScaffoldMessenger.of(context);
        try {
          await feed.removeFromResume(item);
          if (messenger.mounted && feed.current) {
            messenger.showSnackBar(
              const SnackBar(content: Text('已移出继续观看，观看进度保留')),
            );
          }
        } catch (error) {
          if (messenger.mounted && feed.current) {
            messenger.showSnackBar(
              SnackBar(content: Text('移出继续观看：${safeError(error)}')),
            );
          }
        }
      },
    ),
  );
}
