// Full backend methods, production restoration; synthetic player IO only.
import 'dart:io';
import 'dart:async';
import 'package:media_kit/media_kit.dart' show SubtitleTrack, Player;
import 'package:media_kit/src/player/native/player/real.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/tracks.dart';
import 'package:yingyu/playback/subtitle_switch.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
enum LogArea {player}
class Log {void add(LogArea area,String value){}}

class Files {Future<File> load(String id,PlaybackRoute route,String codec)async=>File('C:/synthetic/subtitle.srt');}
class DiscPlacementContext {Object? selected;}
class SubtitleHarness {
 SubtitleHarness(this.player); final Player player;Log? log=Log();final bool _disposed=false;int _loadSerial=0,refreshes=0;
 int _subtitlePlacementGeneration=0;int get placementGeneration=>_subtitlePlacementGeneration;
 final bool _screenCanvas=false;bool _subtitleDiscEmbedded=false;DiscPlacementContext? _disc;
 final _trackMetadata=<String,({bool external})>{};double? _regularSubtitlePosition,_discSubtitlePosition;
 void _selectSubtitlePlacement(bool value){_subtitleDiscEmbedded=value;}
 void emit(){}
 final _externalIds=<String,String>{};final _subtitleFilePaths=<String>{};final _subtitleFiles=Files();
 Map<String,String> get externalIds=>_externalIds;
 Set<String> get privatePaths=>_subtitleFilePaths;
 Future<void> _refreshTracks()async{refreshes++;}
 void retire(){_loadSerial++;}

Future<void> subtitle(TrackOption track) async {
    final native = player.platform;
    if (native is! NativePlayer || _disposed) throw const AppFailure('播放会话已关闭');
    final load = _loadSerial;
    ++_subtitlePlacementGeneration;
    bool active() => !_disposed && load == _loadSerial;
    try {
      await protectSubtitleSwitch(
        read: native.getProperty,
        restore: (key, value) async {
          if (!active()) throw const AppFailure('字幕操作已取消');
          if (key == 'sid') {
            await player.setSubtitleTrack(SubtitleTrack(value, null, null));
          } else {
            await native.setProperty(key, value);
          }
        },
        apply: () => _applySubtitle(track, native, active),
        active: active,
      );
    } finally {
      if (active()) await _refreshTracks();
    }
  }
Future<void> _applySubtitle(
    TrackOption track,
    NativePlayer native,
    bool Function() active,
  ) async {
    if (!active()) throw const AppFailure('字幕操作已取消');
    Future<void> select(SubtitleTrack value) async {
      // media_kit clears its current text cue before setting sid. MPV keeps
      // the same track unchanged, so sub-text need not emit again until the
      // next cue. Preserve that cue when confirming an already selected ID.
      // Off/auto and newly added files retain their existing reset semantics.
      final id = int.tryParse(value.id);
      final same =
          id != null &&
          id > 0 &&
          await native
                  .getProperty('sid')
                  .timeout(const Duration(milliseconds: 600)) ==
              value.id;
      if (!active()) throw const AppFailure('字幕操作已取消');
      if (!same) await player.setSubtitleTrack(value);
    }

    String? addedAddress;
    final saved = _externalIds[track.id];
    if (saved != null) {
      await select(SubtitleTrack(saved, track.title, track.language));
    } else if (track.value case ExternalSubtitle(:final route)) {
      final file = await _subtitleFiles.load(track.id, route, track.codec);
      if (!active()) throw const AppFailure('字幕操作已取消');
      final address = file.uri.toString();
      _subtitleFilePaths.addAll([file.path, address]);
      addedAddress = address;
      await player.setSubtitleTrack(
        SubtitleTrack.uri(
          address,
          title: track.title,
          language: track.language,
        ),
      );
    } else if (track.value case LocalSubtitle(:final path)) {
      final address = Uri.file(path).toString();
      _subtitleFilePaths.addAll([path, address]);
      addedAddress = address;
      await player.setSubtitleTrack(
        SubtitleTrack.uri(
          address,
          title: track.title,
          language: track.language,
        ),
      );
    } else {
      await select(track.value as SubtitleTrack);
    }
    if (!active()) throw const AppFailure('字幕操作已取消');
    final actual = await native.getProperty('sid');
    if (addedAddress != null) {
      final count =
          int.tryParse(await native.getProperty('track-list/count')) ?? 0;
      var confirmed = false;
      for (var i = 0; i < count && i < 512; i++) {
        if (await native.getProperty('track-list/$i/id') == actual &&
            await native.getProperty('track-list/$i/type') == 'sub' &&
            await native.getProperty('track-list/$i/external-filename') ==
                addedAddress) {
          confirmed = true;
          break;
        }
      }
      if (!confirmed) throw const AppFailure('MPV 未确认外挂字幕加载，请重试');
      _externalIds[track.id] = actual;
    } else if (actual != (saved ?? track.id) && track.id != 'auto') {
      throw const AppFailure('MPV 未确认字幕切换，请重试');
    }
    // Preserve the existing Flutter text subtitle renderer. Bitmap subtitles
    // have no sub-text; render only those through MPV's existing video output.
    final visible = track.bitmap && actual != 'no' ? 'yes' : 'no';
    if (!active()) throw const AppFailure('字幕操作已取消');
    await native.setProperty('sub-visibility', visible);
    if (await native.getProperty('sub-visibility') != visible) {
      throw const AppFailure('MPV 未确认字幕显示设置，请重试');
    }
    await _applySubtitleLayoutForTrack(track, actual, native, active);
    log?.add(
      LogArea.player,
      '字幕显示核对：轨道已选择=${actual != "no"}；类型=${track.bitmap ? "图像" : "文字"}；原生图像显示=$visible；部分台词是否显示仍需核对实际字幕事件',
    );
  }
Future<void> _applySubtitleLayoutForTrack(
    TrackOption track,
    String actual,
    NativePlayer native,
    bool Function() active,
  ) async {
    if (!_screenCanvas || actual == 'no') return;
    final discEmbedded =
        _disc?.selected != null &&
        !track.external &&
        track.value is! ExternalSubtitle &&
        track.value is! LocalSubtitle &&
        !_externalIds.values.contains(actual) &&
        _trackMetadata['sub:$actual']?.external != true;
    if (discEmbedded == _subtitleDiscEmbedded) return;
    await writeMpvSubtitleLayout(
      scope: discEmbedded
          ? SubtitlePositionScope.discEmbedded
          : SubtitlePositionScope.regular,
      position: discEmbedded ? _discSubtitlePosition : _regularSubtitlePosition,
      read: native.getProperty,
      write: native.setProperty,
      active: active,
    );
    if (!active()) throw const AppFailure('字幕操作已取消');
    _selectSubtitlePlacement(discEmbedded);
    emit();
  }
}
