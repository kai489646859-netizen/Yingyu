// Complete production admission/settle methods. Native/media IO is synthetic.
// ignore_for_file: unused_element, unused_field, unused_import, override_on_non_overriding_member
import 'dart:async';
import 'package:yingyu/playback/diagnostic_budget.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/playback/native_hdr.dart';
import 'package:yingyu/playback/display_diagnostics.dart';
import 'package:yingyu/playback/opening_output.dart';
import 'package:yingyu/playback/opening_buffer.dart';

class Admission {
 final _diagnosticBudget=DiagnosticBudget();
 void _beginLatency(String phase, Duration target) {}
 final native=NativePlayer();late final player=(platform:native as Object,state:(position:Duration.zero));
 late final _hdr=HdrIo(native);final video=VideoIo();
 LogIo? log=LogIo();final nativeHdr=true;
 final DiscIo? _disc=null;bool _disposed=false,_dolbyMapping=false;
 int _loadSerial=1,_playIntent=0;String? _lastFailure;
 final _hardwareFallback=HardwareIo();
 bool _noticeBluray=false,_noticeReady=false;
 List<Json> _noticeStreams=[];
 Map<String,String> _noticeDecoded={};String get sourceNotice=>'synthetic';
 void _failPlayback(String value){_lastFailure=value;}
 void retire(){_disposed=true;_loadSerial++;_playIntent++;}
 Future<void> record(PlaybackRoute route)=>_recordOutput(route);
 void selectSubtitle(){native.calls.add('sid');native.selectionAfterRefill=_hdr.established;}
 void rejectOutput(){_hdr.failPrepare=true;}
 String? get failure=>_lastFailure;
 bool get cleanOpening=>!native.selectionAfterRefill;
 bool get established=>_hdr.established;
 List<String> get calls=>native.calls;
 void _setStage(String value) {}
   @override
  bool get prepareTracksWhilePaused =>
      _pendingHdrTransfer != null || (_hdr.established && !_hdr.autoDolby);

  String? _pendingHdrTransfer;
  @override
  Future<void> settleOpeningTracks() async {
    final native = player.platform;
    if (native is! NativePlayer || _disposed || _hdr.autoDolby) return;
    final serial = _loadSerial, intent = _playIntent;
    final transfer = _pendingHdrTransfer;
    _pendingHdrTransfer = null;
    if (transfer != null && _lastFailure == null) {
      final attemptClock = Stopwatch()..start();
      try {
        if (await native.getProperty('pause') != 'yes' ||
            _disposed ||
            serial != _loadSerial ||
            intent != _playIntent) {
          return;
        }
        _setStage('正在校验 HDR 显示');
        _beginLatency('hdr_refill', player.state.position);
        final established = _dolbyMapping
            ? await _hdr.prepareDolby()
            : await _hdr.prepare(transfer);
        log?.add(
          LogArea.player,
          'HDR 输出事务：${_hdr.status}；${await video.nativeHdrStatus}',
        );
        if (!established) {
          log?.add(LogArea.player, '原生 HDR 条件未成立，继续兼容显示；本次不再尝试');
        }
        log?.add(
          LogArea.player,
          'HDR 输出协商完成：耗时=${attemptClock.elapsedMilliseconds} ms；已建立=${_hdr.established}；初始轨道已处理',
        );
      } catch (_) {
        log?.add(
          LogArea.player,
          'HDR 输出事务失败：${_hdr.status}；${await video.nativeHdrStatus}',
          level: LogLevel.warning,
        );
        _failPlayback('HDR 输出参数恢复失败，已保留观看进度');
        // errors is an asynchronous stream. Returning normally lets the session
        // mark itself ready and call play before that failure reaches it.
        throw const AppFailure('HDR 输出参数恢复失败，已保留观看进度');
      }
    }
    if (!_hdr.established ||
        _disposed ||
        _lastFailure != null ||
        serial != _loadSerial ||
        intent != _playIntent) {
      return;
    }
    final clock = Stopwatch()..start();
    _setStage('正在衔接播放缓存');
    final result = await settleOpeningBuffer(
      read: native.getProperty,
      active: () =>
          !_disposed &&
          _lastFailure == null &&
          serial == _loadSerial &&
          intent == _playIntent,
    );
    log?.add(
      LogArea.player,
      'HDR 初始轨道衔接：$result；等待=${clock.elapsedMilliseconds} ms；未重新打开媒体',
    );
    if (log?.enabled == true) {
      unawaited(
        displayDiagnostics(
          native.getProperty,
          active: () =>
              !_disposed &&
              !_diagnosticBudget.stopped &&
              serial == _loadSerial &&
              _lastFailure == null,
        ).then((values) {
          if (values.isNotEmpty) {
            log?.add(
              LogArea.player,
              'HDR 最终显示与缓存参数核对：${values.entries.map((e) => '${e.key}=${e.value}').join('；')}',
            );
          }
        }),
      );
    }
  }

  Future<void> _recordOutput(PlaybackRoute route) async {
    final native = player.platform;
    if (native is! NativePlayer || _disposed) return;
    _pendingHdrTransfer = null;
    if (_hdr.autoArmed && !await _hdr.confirmWarm()) {
      // A rejected first frame restored SDR. Release the optional admission
      // owner so the decoded HDR10/HLG transaction can still be considered.
      await _hdr.resetAuto();
    }
    final serial = _loadSerial;
    final values = await openingOutputProperties(
      native.getProperty,
      active: () => !_disposed && serial == _loadSerial,
    );
    if (_disposed || serial != _loadSerial) return;
    var detectedRange = DetectedVideoRange.unknown;
    var detectedContainer = '';
    if (nativeHdr) {
      try {
        final profile = await native.getProperty(
          'yingyu-hdr-source-dv-profile',
        );
        detectedContainer = await native.getProperty('file-format');
        if (_disposed || serial != _loadSerial) return;
        detectedRange = detectVideoRange(values, profile);
        log?.add(
          LogArea.player,
          '实际片源动态范围检测：${detectedRange.name}；依据当前视频轨和已解码色彩，服务器标签仅作参考',
        );
      } catch (_) {
        detectedRange = DetectedVideoRange.unknown;
      }
      // Positive observations of an ordinary HDR frame can supersede an
      // inaccurate server label. Actual Dolby and unknown stay unchanged.
      if (_dolbyMapping &&
          _disc == null &&
          supportedHdrContainer(detectedContainer) &&
          const {
            DetectedVideoRange.hdr10,
            DetectedVideoRange.hlg,
          }.contains(detectedRange)) {
        try {
          await video.setDolbyMapping(false);
        } catch (_) {
          throw const AppFailure('实际片源输出设置恢复失败，已保留观看进度');
        }
        _dolbyMapping = false;
        log?.add(LogArea.player, '当前实际轨为普通 HDR；已撤销服务器杜比标签触发的预设，按实际片源协商显示');
      }
    }
    _hardwareFallback.observeHardware(values['hwdec-current'] ?? '');
    log?.add(
      LogArea.player,
      '实际解码信息：${values.entries.map((e) => '${e.key}=${e.value}').join('；')}',
    );
    _noticeBluray = _disc?.selected != null;
    _noticeStreams = route.streams;
    _noticeDecoded = {
      ...values,
      'dolby-vision-profile':
          values['current-tracks/video/dolby-vision-profile'] ?? '',
    };
    _noticeReady = true;
    if (values['video-params/colormatrix'] == 'dolbyvision') {
      log?.add(
        LogArea.player,
        '检测到杜比视界色彩标记；逐帧映射=${_dolbyMapping ? '已启用' : '未启用'}；不代表设备原生杜比显示或完整 FEL 增强层处理',
        level: LogLevel.warning,
      );
    }
    if (!_hdr.dolbyEstablished &&
        const {'pq', 'hlg'}.contains(values['video-params/gamma'])) {
      // The existing Flutter texture pipeline has no verified Android HDR
      // surface contract. Use MPV's documented SDR tone mapping explicitly.
      for (final entry in const {
        'target-prim': 'bt.709',
        'target-trc': 'bt.1886',
        'tone-mapping': 'bt.2390',
        'dither': 'fruit',
        'dither-depth': '8',
      }.entries) {
        try {
          await native.setProperty(entry.key, entry.value);
          final actual = await native.getProperty('options/${entry.key}');
          log?.add(
            LogArea.player,
            'HDR 显示参数：${entry.key}=$actual（目标为 SDR 兼容显示）',
          );
        } catch (_) {
          log?.add(
            LogArea.player,
            'HDR 显示参数未能设置：${entry.key}',
            level: LogLevel.warning,
          );
        }
      }
    }
    log?.add(LogArea.player, '音频采用解码输出；TrueHD／E-AC-3 不等同于 Atmos 对象输出，未启用直通');
    if (nativeHdr && _disc == null && !_hdr.autoDolby) {
      await _hdr.start();
      try {
        final transfer =
            detectedRange == DetectedVideoRange.dolby && _dolbyMapping
            ? (_hdr.capabilities.hdr.contains(2)
                  ? 'pq'
                  : _hdr.capabilities.hdr.contains(3)
                  ? 'hlg'
                  : null)
            : nativeHdrTransfer(
                requested: nativeHdr,
                disc: _disc != null,
                source: detectedRange,
                container: detectedContainer,
                capabilities: _hdr.capabilities,
              );
        final paused = transfer == null
            ? ''
            : await native.getProperty('pause');
        log?.add(
          LogArea.player,
          'HDR 输出准入：动态范围=${detectedRange.name}；容器=${supportedHdrContainer(detectedContainer) ? detectedContainer : '其他或未知'}；'
          'SDK=${_hdr.capabilities.sdk}；屏幕HDR=${_hdr.capabilities.hdr.toList()..sort()}；'
          '候选=${transfer ?? '无'}；已暂停=$paused',
        );
        if (!_disposed &&
            serial == _loadSerial &&
            transfer != null &&
            paused == 'yes') {
          // Selecting a newly enabled subtitle may refresh the demuxer and
          // invalidate its queues. Finish initial track selection first, then
          // let the existing HDR exact refill rebuild all selected streams.
          // There is still only one HDR attempt and one successful refill.
          _pendingHdrTransfer = transfer;
          log?.add(LogArea.player, 'HDR 输出等待初始轨道处理；保持暂停与加载遮罩');
        }
      } catch (_) {
        log?.add(
          LogArea.player,
          'HDR 输出事务失败：${_hdr.status}；${await video.nativeHdrStatus}',
          level: LogLevel.warning,
        );
        _failPlayback('HDR 输出参数恢复失败，已保留观看进度');
      }
    }
    log?.add(LogArea.player, '当前播放方式提示：$sourceNotice');
    if (log?.enabled == true && _pendingHdrTransfer == null) {
      unawaited(
        displayDiagnostics(
          native.getProperty,
          active: () =>
              !_disposed && !_diagnosticBudget.stopped && serial == _loadSerial,
        ).then((values) {
          if (values.isNotEmpty) {
            log?.add(
              LogArea.player,
              '显示与缓存参数核对：${values.entries.map((e) => '${e.key}=${e.value}').join('；')}；磁盘缓存启用时字节上限仅约束包元数据',
            );
          }
        }),
      );
    }
  }


}
class NativePlayer {
 final calls=<String>[];
 bool selectionAfterRefill=false;
 final values=<String,String>{
 'video-params/gamma':'pq','video-params/primaries':'bt.2020',
 'video-params/colormatrix':'bt.2020-ncl','video-params/pixelformat':'nv12',
 'yingyu-hdr-source-dv-profile':'0','file-format':'mkv','pause':'yes',
 'seeking':'no','paused-for-cache':'no','demuxer-cache-duration':'8',
 'demuxer-cache-idle':'no','eof-reached':'no',
 };
 Future<String> getProperty(String key)async=>values[key]??'';
 Future<void> setProperty(String key,String value)async{values[key]=value;values['options/$key']=value;}
}
class HdrIo {
 bool get dolbyEstablished=>false;String get dolbyHdrLabel=>'杜比映射 HDR10';
 Future<bool> prepareDolby()=>prepare('pq');
 bool get autoDolby=>false;bool get autoArmed=>false;Future<bool> confirmWarm()async=>false;Future<void> resetAuto()async{}
 HdrIo(this.native);final NativePlayer native;
 bool failPrepare=false;
 bool established=false;String get status=>'synthetic';
 final capabilities=const OutputCapabilities(sdk:37,display:0,hdr:{2});
 Future<void> start()async{}
 Future<bool> prepare(String transfer)async{
   if(failPrepare) throw StateError('synthetic output restoration failure');
   native.calls.add('hdr-refill');native.selectionAfterRefill=false;established=true;return true;
 }
}
class VideoIo {
 Future<void> setDolbyMapping(bool value)async{}
 Future<String> get nativeHdrStatus async=>'synthetic';
}
class LogIo {bool get enabled=>false;void add(LogArea area,String value,{LogLevel level=LogLevel.info}){}}
class DiscIo {Object? get selected=>null;}
class HardwareIo {void observeHardware(String value){}}
