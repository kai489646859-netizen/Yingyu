import 'dart:async';
import 'package:yingyu/core/models.dart';
class NativePlayer {
  NativePlayer(this.read);
  final Future<String> Function(String) read;
  Future<String> getProperty(String key) => read(key);
}
class FakeState { bool completed = false; }
class FakePlayer {
  FakePlayer(this.platform);
  final Object platform;
  final state = FakeState();
}
class TrackHarness {

  TrackHarness(Future<String> Function(String) read) : player=FakePlayer(NativePlayer(read));
  final FakePlayer player;
  bool _disposed=false, _tracksBusy=false, _tracksDirty=false;
  final _trackMetadata=<String,({int? pid,int? ffIndex,bool forced,bool external})>{};
  final _externalIds=<String,String>{};
  String? selectedAudioId,selectedSubtitleId;
  int emissions=0;
  void emit(){emissions++;}
  void dispose(){_disposed=true;}
  void dirty(){_tracksDirty=true;}
  Map<String,({int? pid,int? ffIndex,bool forced,bool external})> get metadata=>_trackMetadata;
  Future<void> refresh()=>_refreshTracks();
Future<void> _refreshTracks() async {
    if (_tracksBusy || _disposed || player.state.completed) return;
    final native = player.platform;
    if (native is! NativePlayer) return;
    _tracksBusy = true;
    try {
      do {
        _tracksDirty = false;
        final count =
            int.tryParse(await native.getProperty('track-list/count')) ?? 0;
        if (count < 0 || count > 512) throw const AppFailure('轨道数量超出上限');
        final metadata =
            <String, ({int? pid, int? ffIndex, bool forced, bool external})>{};
        Future<String?> optional(String key) async {
          try {
            return await native.getProperty(key);
          } catch (_) {
            return null;
          }
        }

        for (var i = 0; i < count; i++) {
          if (_disposed) return;
          final prefix = 'track-list/$i/';
          final type = await native.getProperty('${prefix}type');
          if (type != 'sub' && type != 'audio') continue;
          final id = await native.getProperty('${prefix}id');
          metadata['$type:$id'] = (
            pid: int.tryParse(await optional('${prefix}src-id') ?? ''),
            ffIndex: int.tryParse(await optional('${prefix}ff-index') ?? ''),
            forced: await optional('${prefix}forced') == 'yes',
            external: await optional('${prefix}external') == 'yes',
          );
        }
        if (_disposed) return;
        _trackMetadata
          ..clear()
          ..addAll(metadata);
        selectedAudioId = await native.getProperty('aid');
        final sid = await native.getProperty('sid');
        selectedSubtitleId =
            _externalIds.entries
                .where((e) => e.value == sid)
                .map((e) => e.key)
                .firstOrNull ??
            sid;
      } while (_tracksDirty && !_disposed);
      emit();
    } finally {
      _tracksBusy = false;
    }
  }
}
