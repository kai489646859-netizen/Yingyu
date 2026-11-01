// ignore_for_file: prefer_final_fields
// Generated complete production method; native IO and unrelated player fields are synthetic.
import 'dart:async';
import 'package:yingyu/playback/network_recovery.dart';
enum LogArea {network}
class Log {void add(LogArea area,String message){}}
class NativePlayer {
 final gate=Completer<void>();String seekable='yes';
 Future<String> getProperty(String key) async {await gate.future;return seekable;}
}
class Player {final native=NativePlayer();Object get platform=>native;}
class Position {Duration value=const Duration(seconds:50);}
class NetworkBackendHarness implements NetworkRecoveryBackend {
 final player=Player();Log? log=Log();final _runtimePosition=Position();
 Object? _disc,_cachedTransport;String? _lastFailure;
 bool _networkFile=true,_disposed=false,_opening=false,_runtimeRepairBusy=false,_switching=false;
 int _loadSerial=1,_playIntent=1,_seekIntent=1,seeks=0;
 Duration? target;bool? refresh;
 void invalidate(String cause){
  switch(cause){case 'load':_loadSerial++;break;case 'pause':_playIntent++;break;
   case 'seek':_seekIntent++;break;case 'dispose':_disposed=true;break;
   case 'repair':_runtimeRepairBusy=true;break;case 'track':_switching=true;break;
   case 'disc':_disc=Object();break;case 'cached':_cachedTransport=Object();break;}
 }
 Future<void> _seek(Duration value,{required bool refreshNetwork,required bool Function() allowed})async{
  if(!allowed())return;seeks++;target=value;refresh=refreshNetwork;
 }
@override
  Future<void> recoverNetwork(bool Function() current) async {
    // Dart byte readers recover at the exact byte offset themselves.
    if (_disc != null ||
        _cachedTransport != null ||
        !_networkFile ||
        _disposed ||
        _opening ||
        _runtimeRepairBusy ||
        _switching ||
        _lastFailure != null ||
        !current()) {
      return;
    }
    final load = _loadSerial, playIntent = _playIntent;
    final seekIntent = _seekIntent;
    bool active() =>
        !_disposed &&
        !_opening &&
        !_runtimeRepairBusy &&
        !_switching &&
        _lastFailure == null &&
        load == _loadSerial &&
        playIntent == _playIntent &&
        current();
    if (!active()) return;
    final native = player.platform;
    if (native is! NativePlayer ||
        await native
                .getProperty('seekable')
                .timeout(const Duration(milliseconds: 600)) !=
            'yes' ||
        seekIntent != _seekIntent ||
        !active()) {
      return;
    }
    log?.add(LogArea.network, '默认网络已切换且持续缓冲；本次仅刷新同一媒体范围读取，保留倍速与轨道');
    await _seek(_runtimePosition.value, refreshNetwork: true, allowed: active);
  }
}
