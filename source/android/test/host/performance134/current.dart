import 'dart:async';
import 'package:yingyu/playback/opening_surface.dart';
import 'package:yingyu/playback/dolby_source.dart';
enum LogArea {player}
class Log {void add(LogArea a,String s){}}
class NativePlayer {
 final values=<String,String>{};
 Future<String> getProperty(String k,{bool waitForInitialization=true})async=>values[k]??'';
 Future<void> setProperty(String k,String v,{bool waitForInitialization=true})async{values[k]=v;}
}
class Video {
 int preparations=0; final sizes=<List<int>>[];
 Future<void> setDolbyMapping(bool v) async {}
 Future<bool> prepareVideoSurface(int w,int h,bool Function() active)async{preparations++;sizes.add([w,h]);return active();}
}
class Hdr177Stub {
 String status="synthetic";
 Future<void> warmDolby({bool deferHlg=false})async{} Future<bool> claimWarm()async=>false;void cancelWarm(){} Future<void> resetAuto()async{}
}
class Harness {
 final bool nativeHdr=false;final Object? _disc=null;final _hdr=Hdr177Stub();

 final bool _disposed=false;bool _dolbyMapping=false;int _loadSerial=1;String? _lastFailure;
 bool get mapped=>_dolbyMapping;
 final native=NativePlayer(),video=Video();final Log? log=Log();
 final loadClock=Stopwatch()..start();final address='synthetic';final serial=1;final start=Duration.zero;
 late Future<void> Function() _dolbyPreloadedHook;
 Future<void> _prepareOpeningSubtitles(NativePlayer n,String a,Duration s,bool Function() active)async{}
 void _failPlayback(String s){_lastFailure=s;}
 void cancel(){_loadSerial++;}
 Future<void> run() async {install();await _dolbyPreloadedHook();}
 void install(){
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
}
}
