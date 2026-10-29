# Preserve the three tiny ownership boundaries so the delivered DEX can be audited.
-keep class com.yingyu.player.ImageFenceWait { public static void await(android.media.Image); }
-keepnames class com.yingyu.player.NativeHdrBridge
-keepclassmembers class com.yingyu.player.NativeHdrBridge { private static native <methods>; }
-keepnames class io.flutter.embedding.engine.renderer.FlutterRenderer$ImageReaderSurfaceProducer
-keepnames class io.flutter.embedding.engine.renderer.FlutterRenderer$ImageTextureRegistryEntry
-keepclassmembers class io.flutter.embedding.engine.renderer.FlutterRenderer$ImageReaderSurfaceProducer { private void waitOnFence(android.media.Image); }
-keepclassmembers class io.flutter.embedding.engine.renderer.FlutterRenderer$ImageTextureRegistryEntry { private void waitOnFence(android.media.Image); }
