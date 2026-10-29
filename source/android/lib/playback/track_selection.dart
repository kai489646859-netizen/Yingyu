import 'dart:async';
import '../core/log.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'tracks.dart';

/// Selection only. No open/seek/rate/report calls and no media/STRM requests.
class TrackSelection {
  TrackSelection({
    required this.store,
    required this.account,
    required this.itemScope,
    this.seriesScope,
    required this.options,
    required this.apply,
    required this.selected,
    required this.onChanged,
    this.serverDefault,
    this.serverOption,
    this.serverIndex,
    this.restoreServerSelection = true,
    this.active,
    this.inheritedChoices = const {},
  });
  final AppStore store;
  final Session account;
  final String itemScope;
  final String? seriesScope;
  final List<TrackOption> Function(bool) options;
  final Future<void> Function(bool, TrackOption) apply;
  final String? Function(bool) selected;
  final void Function() onChanged;
  final int? Function(bool)? serverDefault;
  final TrackOption? Function(bool, int)? serverOption;
  final int? Function(bool, TrackOption)? serverIndex;
  final bool restoreServerSelection;
  final bool Function()? active;
  final Map<bool, TrackChoice?> inheritedChoices;
  Map<bool, TrackChoice?> get continuityChoices => {
    for (final subtitles in [true, false])
      if (!_ephemeral.contains(subtitles) &&
          (_manual.containsKey(subtitles) ||
              inheritedChoices.containsKey(subtitles) ||
              _choice(subtitles) != null))
        subtitles: _choice(subtitles),
  };
  bool closed = false;
  String? warning;
  final _manual = <bool, TrackChoice?>{};
  final _ephemeral = <bool>{};
  final _lastApplied = <bool, String>{};
  Future<void> _queue = Future.value();
  String _signature = '';
  int _revision = 0;
  final _manualRevision = <bool, int>{};
  bool automatic(bool subtitles) => _choice(subtitles) == null;
  TrackChoice? _choice(bool subtitles) => _manual.containsKey(subtitles)
      ? _manual[subtitles]
      : inheritedChoices.containsKey(subtitles)
      ? inheritedChoices[subtitles]
      : store.trackChoice(account, itemScope, subtitles) ??
            (seriesScope == null
                ? null
                : store.trackChoice(account, seriesScope!, subtitles));

  Future<void> _enqueue(Future<void> Function() work) {
    final result = _queue.then((_) async {
      if (!closed) await work();
    });
    _queue = result.catchError((Object _) {});
    return result;
  }

  /// Same preference policy before MPV's initial seek. This is read-only:
  /// it neither records a successful selection nor changes manual choices.
  TrackOption? openingSubtitle(List<TrackOption> parsed) =>
      closed || active?.call() == false ? null : _target(true, parsed: parsed);

  TrackOption? _target(bool subtitles, {List<TrackOption>? parsed}) {
    final list = parsed ?? options(subtitles);
    final choice = _choice(subtitles);
    final item = store.trackChoice(account, itemScope, subtitles);
    final remembered = choice?.resolve(
      list,
      sameItem:
          _manual.containsKey(subtitles) ||
          !inheritedChoices.containsKey(subtitles) && item != null,
    );
    // Explicit choices always win, including after a restart or a changed
    // server default. A missing track may fall back without erasing the choice.
    if (remembered != null) return remembered;
    if (_manual[subtitles] != null) return null;
    final remote = serverDefault?.call(subtitles);
    final matching = parsed == null || remote == null
        ? const <TrackOption>[]
        : list.where((t) => serverIndex?.call(subtitles, t) == remote).toList();
    final remoteTrack = remote == null
        ? null
        : parsed == null
        ? serverOption?.call(subtitles, remote)
        : matching.length == 1
        ? matching.single
        : null;
    if (restoreServerSelection &&
        !_manual.containsKey(subtitles) &&
        !inheritedChoices.containsKey(subtitles) &&
        (!subtitles || store.autoSubtitles || choice != null) &&
        choice == null &&
        remoteTrack != null) {
      if (subtitles && store.autoSubtitles && remoteTrack.id != 'no') {
        final preferred = preferredSubtitle(list);
        if (preferred != null &&
            (subtitleRank(preferred) ?? 1000) < 20 &&
            (subtitleRank(remoteTrack) ?? 1000) >= 20) {
          return preferred;
        }
      }
      if (subtitles && store.autoSubtitles && remoteTrack.id == 'no') {
        final fallback = preferredSubtitle(list);
        if (fallback != null &&
            subtitleRank(fallback) == null &&
            trackLanguageLabel(fallback.language) == '语言未知') {
          return fallback;
        }
      }
      return remoteTrack;
    }
    if (!subtitles) {
      return null; // Preserve MPV/film audio default, no language preference.
    }
    if (!store.autoSubtitles) {
      return list.where((t) => t.id == 'no').firstOrNull;
    }
    return preferredSubtitle(list) ??
        list.where((t) => t.id == 'no').firstOrNull;
  }

  Future<void> refresh() {
    if (closed || active?.call() == false) return Future.value();
    final signature =
        '${store.autoSubtitles}|${[true, false].map((s) => options(s).map((t) => t.signature).join(';')).join('/')}';
    if (_signature == signature) return _queue;
    _signature = signature;
    final revision = _revision;
    return _enqueue(() async {
      for (final subtitles in [true, false]) {
        if (closed || revision != _revision || active?.call() == false) return;
        final target = _target(subtitles);
        if (target == null || _lastApplied[subtitles] == target.signature) {
          continue;
        }
        // A failed automatic operation is not retried on every position tick.
        _lastApplied[subtitles] = target.signature;
        try {
          if (subtitles || selected(subtitles) != target.id) {
            await apply(subtitles, target);
          }
          if (closed || revision != _revision) return;
          warning = null;
          store.log.add(
            LogArea.player,
            '${subtitles ? "字幕" : "音轨"}自动选择已核对；轨道=${target.id}；模式=${target.id == "no" ? "关闭" : "已选择"}',
          );
        } catch (e) {
          if (closed || revision != _revision) return;
          warning = '${subtitles ? "字幕" : "音轨"}自动选择失败，可在轨道菜单重试：${safeError(e)}';
          store.log.add(LogArea.player, warning!, level: LogLevel.warning);
        }
      }
      if (!closed) onChanged();
    });
  }

  Future<void> choose(
    bool subtitles,
    TrackOption choice, {
    bool remember = true,
  }) {
    ++_revision;
    final request = (_manualRevision[subtitles] ?? 0) + 1;
    _manualRevision[subtitles] = request;
    bool currentRequest() =>
        !closed &&
        active?.call() != false &&
        request == _manualRevision[subtitles];
    return _enqueue(() async {
      if (!currentRequest()) return;
      final list = options(subtitles);
      final current = list
          .where((t) => t.id == choice.id && t.signature == choice.signature)
          .firstOrNull;
      if (current == null) throw const AppFailure('轨道列表已更新，请重新选择');
      final target = current.id == 'auto' && subtitles
          ? (store.autoSubtitles ? preferredSubtitle(list) : null) ??
                list.firstWhere((t) => t.id == 'no')
          : current;
      await apply(subtitles, target);
      if (!currentRequest()) return;
      _manual[subtitles] = current.id == 'auto'
          ? null
          : TrackChoice.fromTrack(current);
      _lastApplied[subtitles] = target.signature;
      if (remember) {
        _ephemeral.remove(subtitles);
      } else {
        _ephemeral.add(subtitles);
      }
      warning = null;
      onChanged();
      if (remember) {
        await store.saveTrackChoice(
          account,
          [itemScope, ?seriesScope],
          subtitles,
          _manual[subtitles],
        );
      }
      store.log.add(
        LogArea.player,
        '${subtitles ? "字幕" : "音轨"}手动选择已核对；轨道=${current.id}',
      );
    });
  }

  void close() {
    closed = true;
    ++_revision;
  }
}
