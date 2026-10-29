// Generated complete method; only NativePlayer IO type is replaced.
// ignore_for_file: unused_import, unused_element, unused_field, curly_braces_in_flow_control_structures, unnecessary_type_check, prefer_final_fields, override_on_non_overriding_member
import 'package:yingyu/core/models.dart';
import 'dart:async';
import 'hdr181_controller.dart';
import 'package:yingyu/playback/opening_output.dart';
import 'package:yingyu/playback/display_diagnostics.dart';
import 'package:yingyu/playback/diagnostic_budget.dart';
import 'package:yingyu/playback/opening_buffer.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/native_hdr_output.dart';
import 'package:yingyu/playback/native_hdr.dart';
import 'package:yingyu/playback/media_notice.dart';
enum LogArea { player }
enum LogLevel { warning }
class Trace { bool enabled=false; final lines=<String>[]; void add(LogArea a,String v,{LogLevel? level}){lines.add(v);} }
class Hardware {void observeHardware(String s){}}
class NativeHarness extends Engine181 {
 NativeHarness(this.container,this.profile,this.gamma);
 final String container,profile,gamma;
 @override Future<String> getOutputProperty(String key)async{
  if(key=='yingyu-hdr-source-dv-profile'||key=='yingyu-preloaded-dolby-vision-profile'||key=='current-tracks/video/dolby-vision-profile')return profile;
  if(key=='file-format')return container;
  if(key=='paused-for-cache')return 'no';if(key=='demuxer-cache-idle')return 'yes';
  final facts={'video-format':'hevc','video-params/primaries':'bt.709','video-params/gamma':gamma,'video-params/colormatrix':'bt.709','video-params/pixelformat':'mediacodec','hwdec-current':'mediacodec','audio-codec-name':'aac','audio-params/channels':'stereo','audio-out-params/channels':'stereo','audio-out-params/format':'float'};
  return facts[key]??await super.getOutputProperty(key);
 }
 Future<void> setProperty(String k,String v)=>setOutputProperty(k,v);
}
class PlayerHarness {PlayerHarness(this.platform);final NativeHarness platform;final state=(position:Duration.zero);}
class VideoHarness {
 VideoHarness(this.native):controller=Controller181(native);final NativeHarness native;final Controller181 controller;
 Future<String> get nativeHdrStatus async=>controller.status;
 Future<bool> setDolbyMapping(bool v)async{controller.mapped=v;return true;}
 Future<bool> write({required int token,required int width,required int height,required String transfer,required bool fill})=>controller.setNativeHdrSurface(token:token,width:width,height:height,transfer:transfer,fill:fill);
}
class RecordHarness {
 final _diagnosticBudget=DiagnosticBudget();
  void _beginLatency(String phase, Duration target) {}
  void _setStage(String value) {}
  RecordHarness({String container='mkv',String profile='0',String gamma='pq'}){
    native=NativeHarness(container,profile,gamma);player=PlayerHarness(native);video=VideoHarness(native);
    _hdr=NativeHdrAdapter(write:video.write,preloadedWrite:video.controller.setPreloadedDolbyHdrSurface,verifyPreloaded:video.controller.confirmPreloadedDolbyHdr,active:()=>!_disposed,message:messages.add,failure:_failPlayback);
  }
  late final NativeHarness native;late final PlayerHarness player;late final VideoHarness video;
  late final NativeHdrAdapter _hdr;NativeHdrAdapter get hdr=>_hdr;
  final messages=<String>[];bool _disposed=false,nativeHdr=true,_dolbyMapping=false,failed=false;
  void enableDolby(){_dolbyMapping=true;video.controller.mapped=true;}
  int _playIntent=0;String? _lastFailure;
  int _loadSerial=1;dynamic _disc;Trace? log=Trace();final _hardwareFallback=Hardware();
  bool _noticeReady=false,_noticeBluray=false;List<Json> _noticeStreams=const [];Map<String,String> _noticeDecoded=const {};
  String? _oldNotice;String get sourceNotice=>_oldNotice??(!_noticeReady?'':mediaNotice(bluray:_noticeBluray,streams:_noticeStreams,decoded:_noticeDecoded,nativeHdr:_hdr.established));
  set sourceNotice(String v){_oldNotice=v;}
  void _failPlayback(String s){failed=true;}
  late PlaybackRoute route;
  Future<void> run() async {await _hdr.start();await _recordOutput(route);if(prepareTracksWhilePaused)await settleOpeningTracks();}
  Future<void> close() async{_disposed=true;await _hdr.close();}
  @override
  bool get prepareTracksWhilePaused =>
      _pendingHdrTransfer != null || (_hdr.established && !_hdr.autoDolby);

  String? _pendingHdrTransfer;
  @override
  Future<void> settleOpeningTracks() async {
    final native = player.platform;
    if (native is! NativeHarness || _disposed || _hdr.autoDolby) return;
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
    if (native is! NativeHarness || _disposed) return;
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
