// Full backend methods, production restoration; synthetic player IO only.
import 'dart:io';
import 'package:media_kit/media_kit.dart' show SubtitleTrack;
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/tracks.dart';
import 'package:yingyu/playback/subtitle_switch.dart';
enum LogArea {player}
class Log {void add(LogArea area,String value){}}
class NativePlayer {
 final values=<String,String>{'sid':'2','sub-visibility':'yes'};
 final commands=<String>[];final entries=<Map<String,String>>[];
 bool mismatch=false;void Function()? afterAdd;
 Future<String> getProperty(String key)async {
  if(key=='track-list/count')return '${entries.length}';
  final m=RegExp(r'^track-list/(\d+)/(.*)$').firstMatch(key);
  return m==null?values[key]??'':entries[int.parse(m[1]!)][m[2]]??'';
 }
 Future<void> setProperty(String k,String v)async{commands.add(k);values[k]=v;}
}
class Player {
 final dynamic platform=NativePlayer();
 Future<void> setSubtitleTrack(SubtitleTrack track)async {
  if(track.uri){
   platform.commands.add('sub-add');final id='${platform.entries.length+10}';
   platform.entries.add({'id':id,'type':'sub','external-filename':platform.mismatch?'unmatched':track.id});
   platform.values['sid']=id;platform.afterAdd?.call();
  }else {platform.commands.add('sid');platform.values['sid']=track.id;}
 }
}
class Files {Future<File> load(String id,PlaybackRoute route,String codec)async=>File('C:/synthetic/subtitle.srt');}
class SubtitleHarness {
 final player=Player();Log? log=Log();final bool _disposed=false;int _loadSerial=0,refreshes=0;
 final _externalIds=<String,String>{};final _subtitleFilePaths=<String>{};final _subtitleFiles=Files();
 Map<String,String> get externalIds=>_externalIds;
 Set<String> get privatePaths=>_subtitleFilePaths;
 Future<void> _refreshTracks()async{refreshes++;}
 void retire(){_loadSerial++;}
Future<void> subtitle(TrackOption track) async {
    final native = player.platform;
    if (native is! NativePlayer || _disposed) throw const AppFailure('播放会话已关闭');
    final load = _loadSerial;
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
    String? addedAddress;
    final saved = _externalIds[track.id];
    if (saved != null) {
      await player.setSubtitleTrack(
        SubtitleTrack(saved, track.title, track.language),
      );
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
    } else {
      await player.setSubtitleTrack(track.value as SubtitleTrack);
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
    await _refreshTracks();
    log?.add(
      LogArea.player,
      '字幕显示核对：轨道已选择=${actual != "no"}；类型=${track.bitmap ? "图像" : "文字"}；原生图像显示=$visible；部分台词是否显示仍需核对实际字幕事件',
    );
  }

}
