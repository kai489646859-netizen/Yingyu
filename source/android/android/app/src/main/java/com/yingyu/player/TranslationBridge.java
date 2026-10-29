package com.yingyu.player;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.os.Handler;
import android.os.Looper;
import com.google.android.gms.tasks.Task;
import com.google.mlkit.common.model.DownloadConditions;
import com.google.mlkit.common.model.RemoteModelManager;
import com.google.mlkit.common.MlKitException;
import com.google.mlkit.nl.translate.*;
import com.google.mlkit.nl.languageid.*;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/** Only public ML Kit APIs. No credentials, media URLs or account data cross this channel. */
public final class TranslationBridge {
    private static TranslationController controller;
    private final Context context;
    private final MethodChannel channel;
    private final Handler main = new Handler(Looper.getMainLooper());
    private boolean destroyed;
    private static synchronized TranslationController runtime(Context context) {
        if (controller == null) {
            SharedPreferences prefs = context.getSharedPreferences("yingyu.offline_translation", Context.MODE_PRIVATE);
            controller = new TranslationController(new MlBackend(), new TranslationController.Consent() {
                public boolean pending() { return prefs.getBoolean("pending", false); }
                public boolean wifiOnly() { return prefs.getBoolean("wifiOnly", true); }
                public void save(boolean pending, boolean wifiOnly) {
                    if (!prefs.edit().putBoolean("pending", pending).putBoolean("wifiOnly", wifiOnly).commit())
                        throw new TranslationController.Failure("storage", "语言包下载选择保存失败");
                }
            });
        }
        return controller;
    }
    public TranslationBridge(Context context, FlutterEngine engine) {
        this.context = context.getApplicationContext();
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/offline_translation");
        channel.setMethodCallHandler((call, result) -> {
            try {
                TranslationController service = runtime(this.context);
                switch (call.method) {
                    case "status": reply(service.status().thenApply(this::networkState), result); break;
                    case "download": {
                        Map<?, ?> args = (Map<?, ?>)call.arguments;
                        result.success(networkState(service.download(Boolean.TRUE.equals(args.get("userInitiated")), !Boolean.FALSE.equals(args.get("wifiOnly")))));
                        break;
                    }
                    case "delete": reply(service.delete().thenApply(this::networkState), result); break;
                    case "translate": {
                        Map<?, ?> args = (Map<?, ?>)call.arguments;
                        reply(service.translate((String)args.get("text")), result); break;
                    }
                    default: result.notImplemented();
                }
            } catch (Exception error) { fail(error, result); }
        });
    }
    private Map<String, Object> networkState(Map<String, Object> value) {
        ConnectivityManager network = (ConnectivityManager)context.getSystemService(Context.CONNECTIVITY_SERVICE);
        NetworkCapabilities capabilities = network == null ? null : network.getNetworkCapabilities(network.getActiveNetwork());
        boolean online = capabilities != null && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        boolean wifi = capabilities != null && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
        value.put("network", !online ? "当前网络未确认可联网" : wifi ? "当前使用 Wi-Fi" : "当前使用其他网络");
        if ("downloading".equals(value.get("phase"))) {
            if (!online) value.put("phase", "waiting_network");
            else if (Boolean.TRUE.equals(value.get("wifiOnly")) && !wifi) value.put("phase", "waiting_wifi");
        }
        return value;
    }
    private <T> void reply(CompletableFuture<T> task, MethodChannel.Result result) {
        task.whenComplete((value, error) -> main.post(() -> {
            if (destroyed) return;
            if (error == null) result.success(value); else fail(error, result);
        }));
    }
    private void fail(Throwable error, MethodChannel.Result result) {
        while (error.getCause() != null) error = error.getCause();
        if (error instanceof TranslationController.Failure) {
            TranslationController.Failure known = (TranslationController.Failure)error;
            result.error(known.code, known.getMessage(), null);
        } else result.error("translation", "离线翻译操作失败，请检查语言包后重试", null);
    }
    public void destroy() { destroyed = true; channel.setMethodCallHandler(null); }

    private static <T> CompletableFuture<T> future(Task<T> task) {
        CompletableFuture<T> value = new CompletableFuture<>();
        task.addOnSuccessListener(value::complete).addOnFailureListener(error -> {
            if (error instanceof MlKitException) value.completeExceptionally(new TranslationController.Failure(
                "sdk", "离线翻译组件失败（错误码 " + ((MlKitException)error).getErrorCode() + "），请检查网络或存储空间后重试"));
            else value.completeExceptionally(error);
        })
            .addOnCanceledListener(() -> value.cancel(false));
        return value;
    }
    private static final class MlBackend implements TranslationController.Backend {
        private TranslateRemoteModel model() { return new TranslateRemoteModel.Builder(TranslateLanguage.CHINESE).build(); }
        public CompletableFuture<Boolean> ready() { return future(RemoteModelManager.getInstance().isModelDownloaded(model())); }
        public CompletableFuture<Void> download(boolean wifiOnly) {
            DownloadConditions.Builder conditions = new DownloadConditions.Builder();
            if (wifiOnly) conditions.requireWifi();
            return future(RemoteModelManager.getInstance().download(model(), conditions.build()));
        }
        public CompletableFuture<Void> delete() { return future(RemoteModelManager.getInstance().deleteDownloadedModel(model())); }
        public CompletableFuture<String> translate(String text) {
            LanguageIdentifier identifier = LanguageIdentification.getClient(
                new LanguageIdentificationOptions.Builder().setConfidenceThreshold(0.6f).build());
            CompletableFuture<String> language = future(identifier.identifyLanguage(text));
            language.whenComplete((v, e) -> identifier.close());
            return language.thenCompose(code -> {
                if (!"en".equals(code)) return TranslationController.failed(new TranslationController.Failure("not_english", "目前仅支持英语简介翻译为中文"));
                Translator translator = Translation.getClient(new TranslatorOptions.Builder()
                    .setSourceLanguage(TranslateLanguage.ENGLISH).setTargetLanguage(TranslateLanguage.CHINESE).build());
                // Never call downloadModelIfNeeded here: translation cannot grant download consent.
                CompletableFuture<String> result;
                try { result = future(translator.translate(text)); }
                catch (RuntimeException error) { translator.close(); throw error; }
                result.whenComplete((v, e) -> translator.close());
                return result;
            });
        }
    }
}
