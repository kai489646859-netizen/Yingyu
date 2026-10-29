import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'style.dart';

String watchTime(Duration value) {
  final s = value.inSeconds.clamp(0, 1 << 40);
  final m = (s ~/ 60 % 60).toString().padLeft(2, '0');
  final sec = (s % 60).toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:$m:$sec' : '$m:$sec';
}

class WatchProgressState {
  const WatchProgressState({
    required this.fraction,
    required this.label,
    required this.completed,
    required this.known,
    this.detail,
    this.position,
  });
  final double fraction;
  final String label;
  final bool completed, known;
  final String? detail;
  final Duration? position;
  factory WatchProgressState.resolve(
    MediaItem item,
    Session? account,
    AppStore? store,
  ) {
    final position = account == null
        ? item.resume
        : store?.resume(account, item).position ?? item.resume;
    var played = object(item.data['UserData'])['Played'] == true;
    var pending = false;
    var completionPending = false, completionSuperseded = false;
    var restart = false;
    String? failure;
    try {
      if (account != null) {
        played = store?.completions.completed(account, item) ?? played;
        completionPending =
            store?.completions.pending(account, item.id) ?? false;
        completionSuperseded =
            store?.completions.superseded(account, item.id) ?? false;
        pending = completionPending;
        restart =
            (store?.restartObserved(account, item) ?? false) &&
            position == Duration.zero;
        pending |=
            restart && store?.localProgress(account, item.id) == Duration.zero;
        pending |=
            store?.resume(account, item).reason.contains('本机未同步') == true;
      }
    } catch (_) {
      failure = '本机已看记录读取失败';
    }
    // Played is historical completion, not the latest viewing position.
    // Only an outstanding real EOF receipt may still be clearing its old
    // checkpoint; subsequent viewing supersedes that receipt.
    final started =
        position > Duration.zero &&
        (!completionPending || completionSuperseded);
    final known = item.duration > Duration.zero;
    final fraction = restart
        ? 0.0
        : played && !started
        ? 1.0
        : known
        ? (position.inMilliseconds / item.duration.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    final label = restart
        ? played
              ? '已看完 · 从头重看'
              : '从头播放'
        : started
        ? '${played ? '已看完 · 重看至' : '看到'} ${watchTime(position)}${known ? ' / ${watchTime(item.duration)}' : ''}'
        : played
        ? '已看完'
        : '未观看';
    final detail = failure ?? (pending ? '待同步 Emby' : null);
    return WatchProgressState(
      position: position,
      fraction: fraction,
      label: label,
      completed: played && !started && !restart,
      known: known,
      detail: detail,
    );
  }
}

class WatchProgress extends StatelessWidget {
  const WatchProgress({
    super.key,
    required this.item,
    required this.account,
    this.store,
  });
  final MediaItem item;
  final Session? account;
  final AppStore? store;
  @override
  Widget build(BuildContext context) {
    final state = WatchProgressState.resolve(item, account, store);
    final label = state.label, detail = state.detail;
    return Semantics(
      label: '$label${detail == null ? '' : ' · $detail'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label${detail == null ? '' : ' · $detail'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: secondaryColor(context)),
          ),
          const SizedBox(height: 5),
          // Unknown durations keep an empty, non-animated bar; no invented %.
          LinearProgressIndicator(
            key: ValueKey('watch-progress-${item.id}'),
            value: state.fraction,
            minHeight: 3,
            borderRadius: BorderRadius.circular(2),
            backgroundColor: secondaryColor(context).withValues(alpha: .15),
            color: accentColor(context),
          ),
        ],
      ),
    );
  }
}
