package io.flutter.plugin.common;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

public final class MethodChannel {
    public static MethodChannel latest;
    private MethodCallHandler handler;
    public MethodChannel(Object messenger, String name) { latest = this; }
    public void setMethodCallHandler(MethodCallHandler value) { handler = value; }
    public interface MethodCallHandler { void onMethodCall(MethodCall call, Result result); }
    public interface Result {
        void success(Object value);
        void error(String code, String message, Object detail);
        void notImplemented();
    }
    public static final class MethodCall {
        public final String method;
        private final Map<String, Object> values;
        MethodCall(String method, Map<String, Object> values) { this.method = method; this.values = values; }
        @SuppressWarnings("unchecked") public <T> T argument(String name) { return (T)values.get(name); }
    }
    public CompletableFuture<Object> call(String method, Map<String, Object> values) {
        CompletableFuture<Object> future = new CompletableFuture<>();
        if (handler == null) { future.completeExceptionally(new IllegalStateException("channel closed")); return future; }
        handler.onMethodCall(new MethodCall(method, values), new Result() {
            public void success(Object value) { future.complete(value); }
            public void error(String code, String message, Object detail) { future.completeExceptionally(new IllegalStateException(message)); }
            public void notImplemented() { future.completeExceptionally(new IllegalStateException("not implemented")); }
        });
        return future;
    }
}
