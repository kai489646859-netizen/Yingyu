import 'package:media_kit/src/player/native/player/real.dart';
// Whole backend method and actual opening helper, native IO is injectable.
import 'package:yingyu/playback/opening_subtitles.dart';
import 'package:yingyu/playback/tracks.dart';
enum LogArea {player}
enum LogLevel {warning}
class Log {final rows=<String>[];void add(LogArea a,String text,{LogLevel? level}){rows.add(text);}}
class Disc {Disc(this.selected);final Title? selected;}
class Title {Title(this.subtitleLanguages);final Map<int,String> subtitleLanguages;}
class HookHarness {
 TrackOption? Function(List<TrackOption>)? openingSecondaryChoice;
 String secondarySubtitleId = 'no';
 Disc? _disc; set discLanguages(Map<int,String> value)=>_disc=Disc(Title(value));
 final _openingSubtitleRead=OpeningSubtitleRead();
 String? expectedAddress;
 TrackOption? Function(List<TrackOption>)? _openingSubtitleChoice;
 final Log? log=Log();String? failure;bool active=true;
 set choose(TrackOption? Function(List<TrackOption>)? value)=>_openingSubtitleChoice=value;
 void _failPlayback(String message){failure=message;}
 Future<bool> beforeOpen(NativePlayer native)=>_openingSubtitleRead.prepare(container:'mkv',read:(k)=>native.getProperty(k,waitForInitialization:false),write:(k,v)=>native.setProperty(k,v,waitForInitialization:false),active:()=>active);
 Future<void> prepare(NativePlayer native,Duration start)async{final address=expectedAddress??await native.getProperty('path',waitForInitialization:false);await _prepareOpeningSubtitles(native,address,start,()=>active);}
 Future<void> restore(NativePlayer native)=>_openingSubtitleRead.restore(read:native.getProperty,write:native.setProperty);
  Future<void> _prepareOpeningSubtitles(
    NativePlayer native,
    String address,
    Duration start,
    bool Function() active,
  ) async {
    final choose = _openingSubtitleChoice;
    if (choose == null || address.isEmpty || !active()) return;
    Future<String> read(String key) =>
        native.getProperty(key, waitForInitialization: false);
    Future<void> write(String key, String value) =>
        native.setProperty(key, value, waitForInitialization: false);
    final before = <String, String>{};
    try {
      if (await read('path') != address || !active()) return;
      final parsed = await readOpeningSubtitles(
        read,
        active,
        discLanguages: _disc?.selected?.subtitleLanguages,
      );
      if (!active() || parsed.length <= 2 || await read('path') != address) {
        return;
      }
      final target = choose(parsed);
      final secondary = openingSecondaryChoice?.call(parsed);
      final secondaryId =
          secondary != null &&
              !secondary.control &&
              !secondary.external &&
              !secondary.bitmap &&
              target?.bitmap != true &&
              secondary.id != target?.id
          ? secondary.id
          : 'no';
      if (secondaryId != 'no' ||
          (int.tryParse(await read('secondary-sid')) ?? 0) > 0) {
        before['secondary-sid'] = await read('secondary-sid');
        await write('secondary-sid', secondaryId);
        if (!active()) return;
        if (await read('secondary-sid') != secondaryId) {
          throw StateError('Secondary subtitle not selected');
        }
        secondarySubtitleId = secondaryId;
      }
      if (target == null ||
          target.external ||
          target.id == 'auto' ||
          !parsed.any((t) => t.id == target.id)) {
        return;
      }
      before['sid'] = await read('options/sid');
      before['sub-visibility'] = await read('sub-visibility');
      if (!active() ||
          !(before['sid'] == 'auto' ||
              before['sid'] == 'no' ||
              int.tryParse(before['sid']!) != null) ||
          !const {'yes', 'no'}.contains(before['sub-visibility'])) {
        return;
      }
      await write('sid', target.id);
      if (!active()) return;
      if (await read('options/sid') != target.id) {
        throw StateError('Initial subtitle not selected');
      }
      final visible = target.id != 'no' && target.bitmap ? 'yes' : 'no';
      await write('sub-visibility', visible);
      if (!active()) return;
      if (await read('sub-visibility') != visible) {
        throw StateError('Initial subtitle visibility not applied');
      }
      var preroll = false;
      if ((target.id != 'no' || secondaryId != 'no') && start > Duration.zero) {
        preroll = await _openingSubtitleRead.prepare(
          container: await read('file-format'),
          read: read,
          write: write,
          active: active,
        );
      }
      if (!active()) return;
      log?.add(
        LogArea.player,
        '续播字幕准备：定位前已选轨道=${target.id}；类型=${target.bitmap ? "图像" : "文字"}；预滚已确认=$preroll；最多提前读取10秒媒体数据；精确目标保持；未代替实际字幕显示核对',
      );
    } catch (_) {
      if (!active()) return;
      for (final key in before.keys.toList().reversed) {
        if (!active()) return;
        await write(key, before[key]!);
        final property = key == 'sid' ? 'options/sid' : key;
        if (await read(property) != before[key]) {
          _failPlayback('续播字幕准备失败，原字幕状态未能恢复');
          return;
        }
      }
      log?.add(
        LogArea.player,
        '定位前字幕准备暂不可用，沿用原轨道选择与真实错误核对',
        level: LogLevel.warning,
      );
    }
  }
}
