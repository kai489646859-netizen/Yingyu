import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show NativePlaybackEvent;
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'host/error096/backend.dart';
void main(){
 test('timeout routing leaves cached playback alive, including after native restart',(){
  final b=ErrorBackendHarness();b.route('ffmpeg','error','tcp: ffurl_read returned 0xffffff92');
  expect(b.errors,isEmpty);b.nativeEvent(const NativePlaybackEvent(mpv.mpv_event_id.MPV_EVENT_PLAYBACK_RESTART));expect(b.errors,isEmpty);
 });
 test('native failure after provisional timeout still fails',(){
  final b=ErrorBackendHarness();b.route('ffmpeg','error','tcp: ffurl_read returned 0xffffff92');
  b.nativeEvent(const NativePlaybackEvent(mpv.mpv_event_id.MPV_EVENT_END_FILE,reason:mpv.mpv_end_file_reason.MPV_END_FILE_REASON_ERROR,error:-13));
  expect(b.errors.single,contains('end-file error=-13'));
 });
 test('premature EOF after provisional timeout remains failure, true EOF stays natural',(){
  final b=ErrorBackendHarness();b.route('ffmpeg','error','tcp: ffurl_read returned 0xffffff92');
  b.nativeEvent(const NativePlaybackEvent(mpv.mpv_event_id.MPV_EVENT_END_FILE,reason:mpv.mpv_end_file_reason.MPV_END_FILE_REASON_EOF));expect(b.errors.single,contains('提前结束'));
  final c=ErrorBackendHarness()..position(const Duration(seconds:100));
  c.nativeEvent(const NativePlaybackEvent(mpv.mpv_event_id.MPV_EVENT_END_FILE,reason:mpv.mpv_end_file_reason.MPV_END_FILE_REASON_EOF));expect(c.errors,isEmpty);
 });
 test('HTTP and other transport errors retain production fatal routing',(){
  final b=ErrorBackendHarness();b.route('ffmpeg','error','tcp: HTTP error 403');expect(b.errors.single,contains('403'));
 });
}
