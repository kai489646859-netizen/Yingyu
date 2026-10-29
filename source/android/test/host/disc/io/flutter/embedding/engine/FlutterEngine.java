package io.flutter.embedding.engine;
public final class FlutterEngine {
    public DartExecutor getDartExecutor() { return new DartExecutor(); }
    public static final class DartExecutor {
        public Object getBinaryMessenger() { return new Object(); }
    }
}
