import 'dart:async';
import 'package:yingyu/playback/disc_startup.dart';
import 'package:yingyu/playback/opening_subtitles.dart';

class NativePlayer {
  Future<void> setProperty(String key,String value)async{}
  final entered = Completer<void>();
  final ready = Completer<void>();
  Future<String> getProperty(String key,{bool waitForInitialization=true}) async {
    if (!entered.isCompleted) entered.complete();
    await ready.future;
    return key=='demuxer-cache-duration'?'4':'no';
  }
}
class State { bool buffering=false; }
class Player {
  Object platform=NativePlayer();
  final state=State();
  int plays=0,pauses=0;
  Future<void> play() async { plays++; }
  Future<void> pause() async { pauses++; }
}
class Disc {
  Object? selected=Object();
  final hints=<bool>[];
  void setBuffering(bool value) { hints.add(value); }
  void stopPersistentReadAhead() {}
}
class Reader { void stopWarming() {} }
class Cache { final reader=Reader(); }
class Audio { void suspend() {} }
enum LogArea { player }
class Log { void add(LogArea area,String text) {} }
abstract class Commands {
  Future<void> play();
  Future<void> pause();
}
class Harness extends Commands {
  final player=Player();
  final _openingSubtitleRead=OpeningSubtitleRead();
  Disc? _disc=Disc();
  Cache? _cachedTransport=Cache();
  final _audioDecode=Audio();
  final Log? log=Log();
  bool _disposed=false,_initialDiscCushionUsed=false,_readAheadAllowed=false;
  int _playIntent=0,_loadSerial=1;
  DateTime? _phonePlayingSince;
  bool get readAhead=>_readAheadAllowed;
  DateTime? get playingSince=>_phonePlayingSince;
  void _updatePersistentReadAhead() {}
  void ordinary() { _disc=null; _cachedTransport=null; }
  void supersede() { _loadSerial++;_playIntent++; }
  void close() { _disposed=true;_playIntent++; }
    @override
  Future<void> play() async {
    final intent = ++_playIntent;
    final serial = _loadSerial;
    final native = player.platform;
    if (!_initialDiscCushionUsed &&
        _disc?.selected != null &&
        native is NativePlayer) {
      _initialDiscCushionUsed = true;
      final clock = Stopwatch()..start();
      final result = await waitForDiscCushion(
        read: (key) => native.getProperty(key, waitForInitialization: false),
        active: () =>
            !_disposed && intent == _playIntent && serial == _loadSerial,
      );
      if (!_disposed && serial == _loadSerial) {
        _disc?.setBuffering(player.state.buffering);
      }
      log?.add(
        LogArea.player,
        '首次播放供数衔接：$result；等待=${clock.elapsedMilliseconds} ms',
      );
    }
    if (_disposed || intent != _playIntent || serial != _loadSerial) return;
    if (native is NativePlayer) {
      await _openingSubtitleRead.restore(
        read: native.getProperty,
        write: native.setProperty,
      );
      if (_disposed || intent != _playIntent || serial != _loadSerial) return;
    }
    _phonePlayingSince ??= DateTime.now();
    _readAheadAllowed = true;
    await player.play();
    _updatePersistentReadAhead();
  }

  @override
  Future<void> pause() async {
    ++_playIntent;
    _audioDecode.suspend();
    _phonePlayingSince = null;
    _readAheadAllowed = false;
    _cachedTransport?.reader.stopWarming();
    _disc?.stopPersistentReadAhead();
    await player.pause();
  }


}
