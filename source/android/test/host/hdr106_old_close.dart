// Whole production detach method; platform IO is synthetic.
// ignore_for_file: override_on_non_overriding_member, unused_field
import 'package:synchronized/synchronized.dart';
class ControllerClose {
 final lock=Lock();bool _canvasClosed=false;int _surfaceSerial=0;
 final _nativeHdrOutput=OutputIo();final platform=PlatformIo();
 bool get closed=>_canvasClosed;bool get cancelled=>_nativeHdrOutput.cancelled;
  @override
  Future<void> detachNativeHdrSurface() => lock.synchronized(() async {
    _canvasClosed = true;
    ++_surfaceSerial;
    await _nativeHdrOutput.detachForClose(
      read: platform.getOutputProperty,
      write: platform.setOutputProperty,
    );
  });

}
class OutputIo {
 bool cancelled=false;
 void cancelForClose(){cancelled=true;}
 Future<void> detachForClose({required Future<String> Function(String) read,required Future<void> Function(String,String) write})async{}
}
class PlatformIo {
 Future<String> getOutputProperty(String key)async=>'';
 Future<void> setOutputProperty(String key,String value)async{}
}
