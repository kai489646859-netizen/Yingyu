package com.yingyu.player;

import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

final class AppUpdateBridge {
    private final MainActivity activity;
    private final MethodChannel channel;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private boolean installing, closed;

    AppUpdateBridge(MainActivity activity, FlutterEngine engine) {
        this.activity = activity;
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/app-update");
        UpdateInstallReceiver.bind(this);
        File directory = new File(activity.getFilesDir(), "app-updates");
        channel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "directory" -> result.success(directory.getAbsolutePath());
                case "permission" -> result.success(activity.getPackageManager().canRequestPackageInstalls());
                case "settings" -> {
                    try {
                        activity.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:" + activity.getPackageName())));
                        result.success(null);
                    } catch (RuntimeException failure) {
                        result.error("settings", "请在系统设置中允许映屿安装应用", null);
                    }
                }
                case "install" -> {
                    String digest = call.argument("digest");
                    String version = call.argument("version");
                    if (installing || "waiting".equals(UpdateInstallReceiver.state) ||
                            "confirming".equals(UpdateInstallReceiver.state) ||
                            digest == null || !digest.matches("[0-9a-f]{64}") ||
                            version == null || !version.matches("[0-9]{1,5}\\.[0-9]{1,5}\\.[0-9]{1,5}")) {
                        result.error("update", "安装任务已开始或更新信息无效", null);
                    } else if (!activity.getPackageManager().canRequestPackageInstalls()) {
                        result.error("permission", "需要系统安装授权", null);
                    } else {
                        installing = true;
                        executor.execute(() -> install(new File(directory, digest + ".apk"), digest, version, result));
                    }
                }
                case "installState" -> result.success(UpdateInstallReceiver.state);
                default -> result.notImplemented();
            }
        });
    }

    @SuppressWarnings("deprecation")
    private static Set<Signature> signers(PackageInfo info) {
        Signature[] all = Build.VERSION.SDK_INT >= 28
            ? (info.signingInfo == null ? null : info.signingInfo.getApkContentsSigners())
            : info.signatures;
        Set<Signature> values = new HashSet<>();
        if (all != null) for (Signature signer : all) values.add(signer);
        return values;
    }

    @SuppressWarnings("deprecation")
    private static long versionCode(PackageInfo info) {
        return Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
    }

    private void install(File apk, String digest, String version, MethodChannel.Result result) {
        PackageInstaller installer = activity.getPackageManager().getPackageInstaller();
        int id = -1;
        try {
            PackageManager manager = activity.getPackageManager();
            int flags = Build.VERSION.SDK_INT >= 28 ? PackageManager.GET_SIGNING_CERTIFICATES
                : PackageManager.GET_SIGNATURES;
            PackageInfo current = manager.getPackageInfo(activity.getPackageName(), flags);
            PackageInfo next = manager.getPackageArchiveInfo(apk.getAbsolutePath(), flags);
            if (next == null || !current.packageName.equals(next.packageName) ||
                    !version.equals(next.versionName) || versionCode(next) <= versionCode(current) ||
                    signers(current).isEmpty() || !signers(current).equals(signers(next))) {
                throw new IllegalArgumentException("APK 与当前正式版包名、签名或版本不匹配");
            }
            PackageInstaller.SessionParams params =
                new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
            params.setAppPackageName(current.packageName);
            params.setSize(apk.length());
            if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(
                PackageInstaller.SessionParams.USER_ACTION_REQUIRED);
            id = installer.createSession(params);
            try (PackageInstaller.Session session = installer.openSession(id)) {
                MessageDigest sha = MessageDigest.getInstance("SHA-256");
                try (FileInputStream input = new FileInputStream(apk);
                        OutputStream output = session.openWrite("base.apk", 0, apk.length())) {
                    byte[] bytes = new byte[256 * 1024];
                    int count;
                    while ((count = input.read(bytes)) != -1) {
                        sha.update(bytes, 0, count);
                        output.write(bytes, 0, count);
                    }
                    session.fsync(output);
                }
                byte[] expected = new byte[32];
                for (int i = 0; i < 32; i++) {
                    expected[i] = (byte) Integer.parseInt(digest.substring(i * 2, i * 2 + 2), 16);
                }
                if (!MessageDigest.isEqual(sha.digest(), expected)) {
                    throw new IllegalArgumentException("APK 校验失败，请删除后重新下载");
                }
                Intent callback = new Intent(activity, UpdateInstallReceiver.class)
                    .setAction(activity.getPackageName() + ".INSTALL_RESULT");
                PendingIntent pending = PendingIntent.getBroadcast(activity, id, callback,
                    PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0));
                UpdateInstallReceiver.committing(id);
                session.commit(pending.getIntentSender());
            }
            activity.runOnUiThread(() -> {
                installing = false;
                if (!closed) result.success(null);
            });
        } catch (Exception failure) {
            if (id >= 0) {
                try { installer.abandonSession(id); } catch (RuntimeException ignored) {}
            }
            final String message = failure instanceof IllegalArgumentException
                ? failure.getMessage() : "无法启动系统安装，请检查存储空间和安装权限";
            final int failedSession = id;
            activity.runOnUiThread(() -> {
                installing = false;
                UpdateInstallReceiver.failed(failedSession);
                if (!closed) result.error("install", message, null);
            });
        }
    }

    void resumed() { UpdateInstallReceiver.resume(activity); }

    void installationChanged(String state) {
        if (!closed) channel.invokeMethod("changed", state);
    }

    void close() {
        closed = true;
        UpdateInstallReceiver.unbind(this);
        channel.setMethodCallHandler(null);
        executor.shutdown();
    }
}
