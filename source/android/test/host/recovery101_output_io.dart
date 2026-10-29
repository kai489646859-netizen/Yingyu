// Generated whole methods, only the MPV IO object is synthetic.
// ignore_for_file: unused_element, unused_field, curly_braces_in_flow_control_structures, avoid_print, non_constant_identifier_names
import 'dart:async';import 'dart:ffi';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
class OutputIo {
 final ctx=Pointer<generated.mpv_handle>.fromAddress(700);
 late final mpv=FakeOutputMpv(_handler);bool disposed=false;int _asyncRequestNumber=1;
 final _setPropertyRequests=<int,Completer<int>>{};
 final _outputPropertyRequests=<int,Completer<String>>{};
 final _commandRequests=<int,Completer<int>>{};
 final configuration=FakeOutputConfig();
 void _logError(int code,String where) {}
 Future<void> userCommand(List<String> args)=>_command(args);
 int get pending=>_setPropertyRequests.length+_outputPropertyRequests.length+_commandRequests.length;
  /// HDR output transactions use acknowledged native IO so a GPU reconfigure
  /// does not synchronously wait on the application's UI isolate.
  Future<void> setOutputProperty(String property, String value) async {
    if (disposed) throw StateError('Output player disposed');
    final request = _asyncRequestNumber++;
    final reply = _setPropertyRequests[request] = Completer<int>();
    final name = property.toNativeUtf8();
    final text = value.toNativeUtf8();
    final data = calloc<Pointer<Utf8>>()..value = text;
    try {
      final result = mpv.mpv_set_property_async(
        ctx,
        request,
        name.cast(),
        generated.mpv_format.MPV_FORMAT_STRING,
        data.cast(),
      );
      if (result < 0) throw StateError('Output property refused');
      final code = await reply.future.timeout(const Duration(seconds: 4));
      if (disposed || code < 0) throw StateError('Output property not applied');
    } finally {
      _setPropertyRequests.remove(request);
      calloc.free(name);
      calloc.free(text);
      calloc.free(data);
    }
  }

  Future<String> getOutputProperty(String property) async {
    if (disposed) throw StateError('Output player disposed');
    final request = _asyncRequestNumber++;
    final reply = _outputPropertyRequests[request] = Completer<String>();
    final name = property.toNativeUtf8();
    try {
      final result = mpv.mpv_get_property_async(
        ctx,
        request,
        name.cast(),
        generated.mpv_format.MPV_FORMAT_STRING,
      );
      if (result < 0) throw StateError('Output property request refused');
      final value = await reply.future.timeout(const Duration(seconds: 4));
      if (disposed) throw StateError('Output player disposed');
      return value;
    } finally {
      _outputPropertyRequests.remove(request);
      calloc.free(name);
    }
  }

  // Media/seek commands issued by the user supersede an output refresh. This
  // counter changes before the native request is submitted, including while
  // the video controller is waiting for its Surface lock.
  int outputEpoch = 0;

  /// Refill a rebuilt decoder at the already displayed position. This uses
  /// acknowledged asynchronous IO without taking the player command lock or
  /// re-entering on_preloaded. It never opens the media again or changes pause.
  Future<void> refreshOutputFrame(String position, {required int epoch}) async {
    final seconds = double.tryParse(position);
    if (disposed || outputEpoch != epoch || seconds == null ||
        !seconds.isFinite || seconds < 0 || seconds >= 1e9) {
      throw StateError('Output refresh superseded or unavailable');
    }
    final request = _asyncRequestNumber++;
    final reply = _commandRequests[request] = Completer<int>();
    final values = ['seek', position, 'absolute+exact']
        .map((value) => value.toNativeUtf8()).toList();
    final args = calloc<Pointer<Utf8>>(values.length + 1);
    try {
      for (var i = 0; i < values.length; i++) {
        args[i] = values[i];
      }
      final code = mpv.mpv_command_async(ctx, request, args.cast());
      if (code < 0) throw StateError('Output refresh refused');
      final result = await reply.future.timeout(const Duration(seconds: 4));
      if (result < 0 || disposed || outputEpoch != epoch) {
        throw StateError('Output refresh not applied');
      }
    } finally {
      _commandRequests.remove(request);
      for (final value in values) {
        calloc.free(value);
      }
      calloc.free(args);
    }
  }

  Future<void> _handler(Pointer<generated.mpv_event> event) async {
    if (event.ref.event_id ==
        generated.mpv_event_id.MPV_EVENT_GET_PROPERTY_REPLY) {
      final reply = _outputPropertyRequests.remove(event.ref.reply_userdata);
      if (reply != null && !reply.isCompleted) {
        final prop = event.ref.data.cast<generated.mpv_event_property>();
        if (event.ref.error < 0 ||
            prop == nullptr ||
            prop.ref.data == nullptr ||
            prop.ref.format != generated.mpv_format.MPV_FORMAT_STRING) {
          reply.complete('');
        } else {
          final text = prop.ref.data.cast<Pointer<Utf8>>().value;
          reply.complete(text == nullptr ? '' : text.toDartString());
        }
      }
      return;
    }

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

  }
  Future<void> _command(List<String> args) async {
    if (args.isNotEmpty && const {
      'seek', 'loadfile', 'loadlist', 'stop', 'playlist-next', 'playlist-prev',
      'playlist-play-index',
    }.contains(args.first)) {
      outputEpoch++;
    }
    final pointers = args.map<Pointer<Utf8>>((e) => e.toNativeUtf8()).toList();
    final arr = calloc<Pointer<Utf8>>(128);
    for (int i = 0; i < args.length; i++) {
      (arr + i).value = pointers[i];
    }

    if (configuration.async) {
      final requestNumber = _asyncRequestNumber++;
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

    calloc.free(arr);
    pointers.forEach(calloc.free);
  }

}

class FakeOutputConfig {bool async=true;}
class FakeOutputMpv {
 FakeOutputMpv(this.handler);final Future<void> Function(Pointer<generated.mpv_event>) handler;
 int result=0;bool deferred=false;final replies=<Future<void> Function()>[];
 String value='pq',property='',written='';int calls=0;
 final commands=<List<String>>[];
 void mpv_command(Pointer<generated.mpv_handle> c,Pointer<Pointer<Char>> args){}
 int mpv_command_async(Pointer<generated.mpv_handle> c,int r,Pointer<Pointer<Char>> args){
  final command=<String>[];for(var i=0;args[i]!=nullptr;i++){command.add(args[i].cast<Utf8>().toDartString());}
  commands.add(command);calls++;submit(()=>reply(r,generated.mpv_event_id.MPV_EVENT_COMMAND_REPLY));return result;
 }
 int mpv_set_property_async(Pointer<generated.mpv_handle> c,int r,Pointer<Char> name,int format,Pointer<Void> data){
  if(format!=generated.mpv_format.MPV_FORMAT_STRING)throw StateError('wrong setter format');
  property=name.cast<Utf8>().toDartString();written=data.cast<Pointer<Utf8>>().value.toDartString();calls++;
  submit(()=>reply(r,generated.mpv_event_id.MPV_EVENT_SET_PROPERTY_REPLY));return result;
 }
 int mpv_get_property_async(Pointer<generated.mpv_handle> c,int r,Pointer<Char> name,int format){
  if(format!=generated.mpv_format.MPV_FORMAT_STRING)throw StateError('wrong getter format');
  property=name.cast<Utf8>().toDartString();calls++;
  submit(()=>reply(r,generated.mpv_event_id.MPV_EVENT_GET_PROPERTY_REPLY));return result;
 }
 void submit(Future<void> Function() action){if(result<0)return;if(deferred){replies.add(action);}else{scheduleMicrotask(action);}}
 int error=0;bool missing=false;
 Future<void> reply(int request,int kind)async{
  final event=calloc<generated.mpv_event>();final prop=calloc<generated.mpv_event_property>();
  final text=value.toNativeUtf8();final data=calloc<Pointer<Utf8>>()..value=text;
  event.ref.event_id=kind;event.ref.reply_userdata=request;event.ref.error=error;
  prop.ref.format=generated.mpv_format.MPV_FORMAT_STRING;prop.ref.data=missing?nullptr:data.cast();event.ref.data=prop.cast();
  try{await handler(event);}finally{calloc.free(text);calloc.free(data);calloc.free(prop);calloc.free(event);}
 }
 Future<void> flush()async{for(final reply in List.of(replies)){await reply();}replies.clear();}
}
