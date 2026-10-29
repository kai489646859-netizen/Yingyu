// ignore_for_file: unused_element, curly_braces_in_flow_control_structures, avoid_print, non_constant_identifier_names, dangling_library_doc_comments, unintended_html_in_doc_comment
/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:collection';
import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:synchronized/synchronized.dart';

/// {@template initializer_native_callable}
///
/// InitializerNativeCallable
/// -------------------------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// {@endtemplate}
class InitializerNativeCallable {
  /// Singleton instance.
  static InitializerNativeCallable? _instance;

  /// {@macro initializer}
  InitializerNativeCallable._(this.mpv);

  /// {@macro initializer}
  factory InitializerNativeCallable(FakeMpv mpv) {
    _instance ??= InitializerNativeCallable._(mpv);
    return _instance!;
  }

  /// Generated libmpv C API bindings.
  final FakeMpv mpv;

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    final ctx = mpv.mpv_create();
    for (final entry in options.entries) {
      final name = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      mpv.mpv_set_option_string(ctx, name.cast(), value.cast());
      calloc.free(name);
      calloc.free(value);
    }
    mpv.mpv_initialize(ctx);
    final nativeCallable = WakeUpNativeCallable.listener(_callback);
    final nativeFunction = nativeCallable.nativeFunction;
    _locks[ctx.address] = Lock();
    _eventCallbacks[ctx.address] = callback;
    _wakeUpNativeCallables[ctx.address] = nativeCallable;
    mpv.mpv_set_wakeup_callback(ctx, nativeFunction.cast(), ctx.cast());
    return ctx;
  }

  /// Disposes [Pointer<mpv_handle>].
  void dispose(Pointer<generated.mpv_handle> ctx) {
    _locks.remove(ctx.address);
    _eventCallbacks.remove(ctx.address);

    // Clear the wakeup callback in libmpv before closing NativeCallable
    // to prevent libmpv from invoking a deleted callback
    mpv.mpv_set_wakeup_callback(ctx, nullptr, nullptr);
    
    _wakeUpNativeCallables.remove(ctx.address)?.close();
  }

  void _callback(Pointer<generated.mpv_handle> ctx) {
    _locks[ctx.address]?.synchronized(() async {
      while (true) {
        final event = mpv.mpv_wait_event(ctx, 0);
        if (event == nullptr) return;
        if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_NONE) return;
        await _eventCallbacks[ctx.address]?.call(event);
      }
    });
  }

  static void resetForTest() { _instance = null; }
  void dispatch(Pointer<generated.mpv_handle> ctx) => _callback(ctx);
  final _locks = HashMap<int, Lock>();
  final _eventCallbacks = EventCallbackMap();
  final _wakeUpNativeCallables = WakeUpNativeCallableMap();
}

typedef WakeUpCallback = Void Function(Pointer<generated.mpv_handle>);
typedef WakeUpNativeCallable = NativeCallable<WakeUpCallback>;
typedef WakeUpNativeCallableMap = HashMap<int, WakeUpNativeCallable>;

typedef EventCallback = Future<void> Function(Pointer<generated.mpv_event>);
typedef EventCallbackMap = HashMap<int, EventCallback>;

class FakeMpv {
 final queue=<int>[];int waits=0;final event=calloc<generated.mpv_event>();
 Pointer<generated.mpv_handle> mpv_create()=>Pointer.fromAddress(700);
 int mpv_set_option_string(Pointer<generated.mpv_handle> c,Pointer<Char> n,Pointer<Char> v)=>0;
 int mpv_initialize(Pointer<generated.mpv_handle> c)=>0;
 void mpv_set_wakeup_callback(Pointer<generated.mpv_handle> c,dynamic f,dynamic u){}
 Pointer<generated.mpv_event> mpv_wait_event(Pointer<generated.mpv_handle> c,double timeout){
  if(timeout!=0)throw StateError('blocking event poll');
  waits++;event.ref.event_id=queue.isEmpty?0:queue.removeAt(0);return event;
 }
 void close()=>calloc.free(event);
}
