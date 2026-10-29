// Whole production preloaded hook, synthetic native IO; no media/decoder.
// ignore_for_file: unused_field, unused_element, prefer_final_fields
import 'dart:async';
import 'package:yingyu/playback/dolby_source.dart';
import 'package:yingyu/playback/opening_surface.dart';
enum LogArea {player}
class Log {void add(LogArea area,String message){}}
class Clock {int elapsedMilliseconds=0;}
class Native {
 final values=<String,String>{'path':'synthetic','yingyu-preloaded-dolby-vision-profile':'7','vid':'auto','track-list/count':'1','track-list/0/type':'video','track-list/0/id':'1','track-list/0/image':'no','track-list/0/albumart':'no','track-list/0/demux-w':'3840','track-list/0/demux-h':'2160','track-list/0/demux-rotation':'0'};
 Future<String> getProperty(String k,{bool waitForInitialization=true})async=>values[k]??'unavailable';
 Future<void> setProperty(String k,String v,{bool waitForInitialization=true})async{values[k]=v;}
}
class Video {
 bool prepared=false;int prepares=0;bool mapped=false;
 Future<bool> setDolbyMapping(bool value)async{mapped=value;return true;}
 Future<bool> prepareVideoSurface(int width,int height,[bool Function()? active])async{if(active?.call()==false)return false;prepares++;prepared=width>1&&height>1;return prepared;}
}
class HdrPreview177 {
 String status='synthetic';int warms=0,claims=0,cancels=0;bool ready=false;Completer<void>? pending;
 Future<void> warmDolby({bool deferHlg=false})async{warms++;if(pending!=null)await pending!.future;}
 Future<bool> claimWarm()async{claims++;return ready;}
 Future<void> resetAuto()async{}
 void cancelWarm(){cancels++;}
}
class HookHarness {
 bool nativeHdr=false;Object? _disc;final _hdr=HdrPreview177();HdrPreview177 get hdr=>_hdr;

 final native=Native();final video=Video();Log? log=Log();final loadClock=Clock();
 final start=Duration.zero; Future<void> _prepareOpeningSubtitles(Native native,String address,Duration start,bool Function() active)async{}
 final address='synthetic';bool _disposed=false,_dolbyMapping=false;int _loadSerial=1;Object? _lastFailure;
 Future<void> Function()? _dolbyPreloadedHook;
 String? get failure=>_lastFailure?.toString();
 void _failPlayback(String message){_lastFailure=message;}
 Future<void> preload()async{final serial=_loadSerial;
        _dolbyPreloadedHook = () async {
          bool active() =>
              !_disposed && serial == _loadSerial && _lastFailure == null;
          if (!active()) return;
          await _prepareOpeningSubtitles(native, address, start, active);
          if (!active()) return;
          log?.add(
            LogArea.player,
            '内核开播分段：本次媒体解析完成=${loadClock.elapsedMilliseconds} ms；尚未确认出画',
          );
          try {
            final profile = await prepareOpenedDolby(
              address: address,
              read: (key) =>
                  native.getProperty(key, waitForInitialization: false),
              enable: () async {
                await video.setDolbyMapping(true);
                _dolbyMapping = true;
              },
              active: active,
            );
            if (!active()) return;
            if (nativeHdr && profile != null) {
              unawaited(_hdr.warmDolby(deferHlg: true));
            } else {
              _hdr.cancelWarm();
            }
            {
              final surfaceClock = Stopwatch()..start();
              final prepared = await prepareOpenedVideoSurface(
                address: address,
                read: (key) =>
                    native.getProperty(key, waitForInitialization: false),
                prepare: (w, h) => video.prepareVideoSurface(w, h, active),
                active: active,
              );
              if (!active()) return;
              var hardwarePolicy = '未提供';
              try {
                final value = await native.getProperty(
                  'options/hwdec',
                  waitForInitialization: false,
                );
                if (const {
                  'auto',
                  'auto-safe',
                  'mediacodec',
                  'mediacodec-copy',
                  'no',
                }.contains(value)) {
                  hardwarePolicy = value;
                }
              } catch (_) {
                /* Optional startup diagnostic. */
              }
              if (!active()) return;
              log?.add(
                LogArea.player,
                '解码前画面表面准备：已确认=$prepared；耗时=${surfaceClock.elapsedMilliseconds} ms；硬解策略=$hardwarePolicy；未代替实际出画核对',
              );
            }
            if (!active()) {
              _hdr.cancelWarm();
              return;
            }
            if (nativeHdr && profile != null && _disc == null) {
              final selected = await _hdr.claimWarm();
              log?.add(
                LogArea.player,
                selected
                    ? '[HDR180] 解码前已选择就绪的杜比HDR窗口；不重开媒体或定位'
                    : '[HDR180] HDR候选未通过准入，沿用当前SDR；原因=${_hdr.status}',
              );
              if (!selected) await _hdr.resetAuto();
            } else {
              _hdr.cancelWarm();
            }
            log?.add(
              LogArea.player,
              profile == null
                  ? '实际媒体已解析：容器未提供可用杜比 Profile；保留已有片源设置，不能据此排除杜比'
                  : '实际媒体识别：杜比视界 Profile $profile；已在解码前启用逐帧映射；复用本次取流',
            );
          } catch (_) {
            if (!active()) return;
            await native.setProperty(
              'pause',
              'yes',
              waitForInitialization: false,
            );
            _failPlayback('已识别杜比资源，但杜比输出初始化失败，已保留观看进度');
          }
        };
await _dolbyPreloadedHook!();}
}
