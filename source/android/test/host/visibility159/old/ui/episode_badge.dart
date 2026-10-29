import 'package:flutter/material.dart';
import '../core/models.dart';
import 'style.dart';

/// PC 0.6.5's display rule: use the server's non-negative series item count.
/// Missing counts remain absent; a season count is never used as an episode count.
class EpisodeBadge extends StatelessWidget {
  const EpisodeBadge({super.key, required this.item});
  final MediaItem item;
  @override
  Widget build(BuildContext context) {
    final value = item.data['RecursiveItemCount'];
    final count = value is int ? value : int.tryParse('$value');
    if (!item.series || count == null || count < 0) {
      return const SizedBox.shrink();
    }
    return Positioned(
      top: 6,
      right: 6,
      child: IgnorePointer(
        child: Semantics(
          label: 'Emby 中已有 $count 集',
          child: Container(
            key: ValueKey('episode-count-${item.id}'),
            padding: EdgeInsets.symmetric(
              horizontal: phoneValue(context, 5, 7),
              vertical: phoneValue(context, 3, 4),
            ),
            decoration: BoxDecoration(
              color: const Color(0xD9232328),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: const Color(0x44FFFFFF)),
            ),
            child: Text(
              '$count 集',
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: Colors.white,
                fontSize: phoneValue(context, 10, 11),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
