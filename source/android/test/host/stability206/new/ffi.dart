// Complete production methods and reply handlers; synthetic MPV transport only.
// ignore_for_file: non_constant_identifier_names, unused_element, avoid_print, deprecated_member_use
import 'dart:async';
import 'dart:ffi';
import 'package:media_kit/ffi/ffi.dart' hide calloc;
import 'package:media_kit/ffi/ffi.dart' as memory;
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;

class CountedAllocator implements Allocator {
 final live=<int,Pointer>{};
 @override Pointer<T> allocate<T extends NativeType>(int bytes,{int? alignment}) {
  final p=memory.calloc.allocate<T>(bytes,alignment:alignment);live[p.address]=p;return p;
 }
 @override void free(Pointer p) {
  if(live.remove(p.address)==null) throw StateError('duplicate/unowned free');
  memory.calloc.free(p);
 }
 void clean(){for(final p in live.values.toList()){free(p);}}
}
class Config206 {bool async=true;}
class Io206 {
 final calloc=CountedAllocator();
 final configuration=Config206();
 final ctx=Pointer<generated.mpv_handle>.fromAddress(1);
 late final mpv=Mpv206(reply);
 int outputEpoch=0,_asyncRequestNumber=0;
 final _setPropertyRequests=<int,Completer<int>>{};
 final _commandRequests=<int,Completer<int>>{};
 final errors=<int>[];
 int get pending=>_setPropertyRequests.length+_commandRequests.length;
 void _logError(int code,String text){if(code<0)errors.add(code);}
 Future<void> flag()=>_setPropertyFlag('pause',true);
 Future<void> number()=>_setPropertyDouble('speed',2.0);
 Future<void> integer()=>_setPropertyInt64('aid',2);
 Future<void> string()=>_setPropertyString('sid','no');
 Future<void> command(List<String> args)=>_command(args);
 void reply(int id,int type,int code){
  final event=memory.calloc<generated.mpv_event>();
  event.ref.event_id=type;event.ref.reply_userdata=id;event.ref.error=code;
  try {
    if (event.ref.event_id ==
        generated.mpv_event_id.MPV_EVENT_SET_PROPERTY_REPLY) {
      final completer = _setPropertyRequests.remove(event.ref.reply_userdata);
      if (completer == null) {
        print(
            'Warning: Received MPV_EVENT_SET_PROPERTY_REPLY with unregistered ID ${event.ref.reply_userdata}');
      } else {
        completer.complete(event.ref.error);
      }
    }
    if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_COMMAND_REPLY) {
      final completer = _commandRequests.remove(event.ref.reply_userdata);
      if (completer == null) {
        print(
            'Warning: Received MPV_EVENT_COMMAND_REPLY with unregistered ID ${event.ref.reply_userdata}');
      } else {
        completer.complete(event.ref.error);
      }
    }


  } finally {memory.calloc.free(event);}
 }
  Future<void> _setProperty(String name, int format, Pointer<Void> data) async {
    int? requestNumber;
    final namePtr = name.toNativeUtf8(allocator: calloc);
    try {
      if (configuration.async) {
        requestNumber = _asyncRequestNumber++;
        final completer = _setPropertyRequests[requestNumber] =
            Completer<int>();
        final immediate = mpv.mpv_set_property_async(
          ctx,
          requestNumber,
          namePtr.cast(),
          format,
          data,
        );
        final text = '_setProperty($name, $format)';
        if (immediate < 0) {
          // Sending failed.
          _logError(immediate, text);
          return;
        }
        _logError(await completer.future, text);
      } else {
        mpv.mpv_set_property(ctx, namePtr.cast(), format, data);
      }
    } finally {
      if (requestNumber != null) _setPropertyRequests.remove(requestNumber);
      calloc.free(namePtr);
    }
  }

  Future<void> _setPropertyFlag(String name, bool value) async {
    final ptr = calloc<Bool>(1)..value = value;
    try {
      await _setProperty(
        name,
        generated.mpv_format.MPV_FORMAT_FLAG,
        ptr.cast(),
      );
    } finally {
      calloc.free(ptr);
    }
  }

  Future<void> _setPropertyDouble(String name, double value) async {
    final ptr = calloc<Double>(1)..value = value;
    try {
      await _setProperty(
        name,
        generated.mpv_format.MPV_FORMAT_DOUBLE,
        ptr.cast(),
      );
    } finally {
      calloc.free(ptr);
    }
  }

  Future<void> _setPropertyInt64(String name, int value) async {
    final ptr = calloc<Int64>(1)..value = value;
    try {
      await _setProperty(
        name,
        generated.mpv_format.MPV_FORMAT_INT64,
        ptr.cast(),
      );
    } finally {
      calloc.free(ptr);
    }
  }

  Future<void> _setPropertyString(String name, String value) async {
    final string = value.toNativeUtf8(allocator: calloc);
    // API requires char**.
    final ptr = calloc<Pointer<Void>>(1);
    ptr.value = Pointer.fromAddress(string.address);
    try {
      await _setProperty(
        name,
        generated.mpv_format.MPV_FORMAT_STRING,
        ptr.cast(),
      );
    } finally {
      calloc.free(ptr);
      calloc.free(string);
    }
  }

  Future<void> _command(List<String> args) async {
    if (args.isNotEmpty &&
        const {
          'seek',
          'loadfile',
          'loadlist',
          'stop',
          'playlist-next',
          'playlist-prev',
          'playlist-play-index',
        }.contains(args.first)) {
      outputEpoch++;
    }
    final pointers = args.map<Pointer<Utf8>>((e) => e.toNativeUtf8(allocator: calloc)).toList();
    final arr = calloc<Pointer<Utf8>>(args.length + 1);
    for (int i = 0; i < args.length; i++) {
      (arr + i).value = pointers[i];
    }

    int? requestNumber;
    try {
      if (configuration.async) {
        requestNumber = _asyncRequestNumber++;
        final completer = _commandRequests[requestNumber] = Completer<int>();
        final immediate = mpv.mpv_command_async(ctx, requestNumber, arr.cast());
        final text = '_command(${args.join(', ')})';
        if (immediate < 0) {
          // Sending failed.
          _logError(immediate, text);
          return;
        }
        _logError(await completer.future, text);
      } else {
        mpv.mpv_command(ctx, arr.cast());
      }
    } finally {
      if (requestNumber != null) _commandRequests.remove(requestNumber);
      calloc.free(arr);
      pointers.forEach(calloc.free);
    }
  }


}
class Mpv206 {
 Mpv206(this.reply);
 final void Function(int,int,int) reply;
 int immediate=0,result=0,calls=0;
 bool throws=false,hold=false;
 final waiting=<void Function()>[];
 List<String> commandArgs=[];
 final properties=<String>[];
 int send(int id,int type){
  calls++;
  if(throws)throw StateError('native bridge failure');
  if(immediate>=0){
   void complete()=>reply(id,type,result);
   if(hold){waiting.add(complete);}else{scheduleMicrotask(complete);}
  }
  return immediate;
 }
 int mpv_set_property_async(Pointer c,int id,Pointer<Char> name,int format,Pointer data){
  properties.add(name.cast<Utf8>().toDartString());
  return send(id,generated.mpv_event_id.MPV_EVENT_SET_PROPERTY_REPLY);
 }
 int mpv_set_property(Pointer c,Pointer<Char> name,int format,Pointer data){
  calls++;if(throws)throw StateError('native bridge failure');return result;
 }
 void capture(Pointer<Pointer<Char>> args){
  commandArgs=[];
  for(var i=0;args[i]!=nullptr;i++){commandArgs.add(args[i].cast<Utf8>().toDartString());}
 }
 int mpv_command_async(Pointer c,int id,Pointer<Pointer<Char>> args){
  capture(args);return send(id,generated.mpv_event_id.MPV_EVENT_COMMAND_REPLY);
 }
 int mpv_command(Pointer c,Pointer<Pointer<Char>> args){
  capture(args);calls++;if(throws)throw StateError('native bridge failure');return result;
 }
}
