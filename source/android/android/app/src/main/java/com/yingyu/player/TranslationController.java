package com.yingyu.player;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.function.LongSupplier;

/** Account-free model management. Backend tests never load Android or ML Kit. */
public final class TranslationController {
    public interface Backend {
        CompletableFuture<Boolean> ready();
        CompletableFuture<Void> download(boolean wifiOnly);
        CompletableFuture<Void> delete();
        CompletableFuture<String> translate(String text);
    }
    public interface Consent {
        boolean pending();
        boolean wifiOnly();
        void save(boolean pending, boolean wifiOnly);
    }
    public static final class Failure extends RuntimeException {
        public final String code;
        public Failure(String code, String message) { super(message); this.code = code; }
    }
    private final Backend backend;
    private final Consent consent;
    private final LongSupplier clock;
    private boolean ready, downloading, deleting;
    private long started, elapsed;
    private String error;
    private int revision;
    private CompletableFuture<Void> translations = CompletableFuture.completedFuture(null);
    public TranslationController(Backend backend, Consent consent) {
        this(backend, consent, () -> System.nanoTime() / 1000000L);
    }
    public TranslationController(Backend backend, Consent consent, LongSupplier clock) {
        this.backend = backend; this.consent = consent; this.clock = clock;
    }
    public synchronized Map<String, Object> snapshot() {
        Map<String, Object> value = new HashMap<>();
        value.put("ready", ready);
        value.put("phase", deleting ? "deleting" : downloading ? "downloading" : error != null ? "error" : ready ? "ready" : consent.pending() ? "pending" : "idle");
        value.put("wifiOnly", consent.wifiOnly());
        value.put("elapsedMs", downloading ? Math.max(0, clock.getAsLong() - started) : elapsed);
        if (error != null) value.put("error", error);
        return value;
    }
    public CompletableFuture<Map<String, Object>> status() {
        final int expected;
        synchronized (this) {
            expected = revision;
            // Reading status never creates or reattaches a download. After restart
            // the user explicitly presses Continue; an already installed model is reused.
        }
        return backend.ready().thenApply(found -> {
            synchronized (this) {
                if (expected == revision && !deleting) ready = found;
                return snapshot();
            }
        });
    }
    public synchronized Map<String, Object> download(boolean userInitiated, boolean wifiOnly) {
        if (!userInitiated) throw new Failure("consent", "请点击下载语言包");
        if (!downloading && !deleting && !ready) startDownload(wifiOnly);
        return snapshot();
    }
    private synchronized void startDownload(boolean wifiOnly) {
        if (downloading || deleting) return;
        consent.save(true, wifiOnly);
        downloading = true;
        started = clock.getAsLong();
        elapsed = 0;
        error = null;
        final int expected = ++revision;
        try {
            backend.download(wifiOnly).thenCompose(ignored -> backend.ready()).whenComplete((found, failure) -> {
                synchronized (this) {
                    if (expected != revision) return;
                    downloading = false;
                    elapsed = Math.max(0, clock.getAsLong() - started);
                    ready = failure == null && Boolean.TRUE.equals(found);
                    error = ready ? null : "语言包下载失败，请检查网络、存储空间或稍后重试";
                    if (!ready && failure != null) {
                        while (failure.getCause() != null) failure = failure.getCause();
                        if (failure instanceof Failure) error = failure.getMessage();
                    }
                    try { consent.save(false, wifiOnly); }
                    catch (RuntimeException storageFailure) {
                        error = "语言包状态保存失败，请检查存储空间后重试";
                    }
                }
            });
        } catch (RuntimeException failure) {
            downloading = false;
            elapsed = Math.max(0, clock.getAsLong() - started);
            error = "无法开始语言包下载，请稍后重试";
            consent.save(false, wifiOnly);
        }
    }
    public synchronized CompletableFuture<Map<String, Object>> delete() {
        if (downloading || deleting) return failed(new Failure("busy", "语言包正在处理，请稍后重试"));
        consent.save(false, consent.wifiOnly());
        deleting = true;
        elapsed = 0;
        error = null;
        ++revision;
        return translations.handle((ignored, failure) -> null)
            .thenCompose(ignored -> backend.delete())
            .thenCompose(ignored -> backend.ready())
            .handle((found, failure) -> {
                synchronized (this) {
                    deleting = false;
                    if (failure == null) ready = found;
                    error = failure == null && !Boolean.TRUE.equals(found) ? null : "语言包删除失败，请重试";
                    return snapshot();
                }
            });
    }
    public synchronized CompletableFuture<String> translate(String text) {
        if (text == null || text.trim().isEmpty() || text.length() > 16000)
            return failed(new Failure("invalid_text", "简介过长或为空，无法翻译"));
        if (downloading || deleting) return failed(new Failure("busy", "语言包正在处理，请稍后重试"));
        final int expected = revision;
        CompletableFuture<String> result = translations.handle((v, e) -> null).thenCompose(v -> {
            synchronized (this) {
                if (expected != revision || deleting) return failed(new Failure("busy", "语言包状态已改变"));
            }
            return backend.ready().thenCompose(found -> {
                synchronized (this) {
                    if (expected != revision || deleting) return failed(new Failure("busy", "语言包状态已改变"));
                    ready = found;
                    if (!found) return failed(new Failure("missing_model", "请先下载离线语言包"));
                }
                return backend.translate(text);
            });
        });
        translations = result.handle((v, e) -> null);
        return result;
    }
    public static <T> CompletableFuture<T> failed(Throwable error) {
        CompletableFuture<T> result = new CompletableFuture<>();
        result.completeExceptionally(error);
        return result;
    }
}
