package com.yingyu.player;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/** User-selected text export. No broad storage permission or large IPC payload. */
final class LogExportBridge {
    static final int REQUEST = 7104;
    private final Activity activity;
    private final MethodChannel channel;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private File staged;
    private MethodChannel.Result pending;
    private boolean destroyed;
    private boolean copying;
    private boolean importing;

    LogExportBridge(Activity activity, FlutterEngine engine) {
        this.activity = activity;
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/log-export");
        channel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "openSettings":
                        if (pending != null || staged != null) {
                            result.error("busy", "已有文件操作正在进行", null); return;
                        }
                        Intent open = new Intent(Intent.ACTION_OPEN_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
                        importing = true;
                        pending = result;
                        activity.startActivityForResult(open, REQUEST); return;
                    case "prepare":
                        if (staged != null || pending != null) {
                            result.error("busy", "已有日志正在导出", null); return;
                        }
                        staged = File.createTempFile("yingyu-log-", ".txt", activity.getCacheDir());
                        result.success(staged.getAbsolutePath()); return;
                    case "save":
                    case "saveSettings":
                        if (pending != null || staged == null || !staged.isFile()) {
                            result.error("unavailable", "日志文件尚未准备好", null); return;
                        }
                        String name = (String) call.arguments;
                        boolean settings = call.method.equals("saveSettings");
                        String extension = settings ? ".json" : ".txt";
                        if (name == null || name.contains("/") || name.contains("\\") || !name.endsWith(extension)) {
                            result.error("name", "日志文件名无效", null); return;
                        }
                        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType(settings ? "application/json" : "text/plain")
                            .putExtra(Intent.EXTRA_TITLE, name);
                        pending = result;
                        activity.startActivityForResult(intent, REQUEST); return;
                    case "discard":
                        if (pending == null) cleanup();
                        result.success(null); return;
                    default: result.notImplemented();
                }
            } catch (Exception error) {
                boolean opening = importing;
                importing = false;
                pending = null;
                cleanup();
                result.error(opening ? "read" : "export",
                    opening ? "无法打开文件选择窗口" : "无法打开保存窗口，请使用分段复制", null);
            }
        });
    }

    void result(int resultCode, Intent data) {
        if (pending == null) return;
        Uri destination = data == null ? null : data.getData();
        if (resultCode != Activity.RESULT_OK || destination == null) {
            finish(importing ? null : false, null); return;
        }
        if (importing) {
            readSettings(destination);
            return;
        }
        final File source = staged;
        copying = true;
        worker.execute(() -> {
            String failure = null;
            try (FileInputStream in = new FileInputStream(source);
                 OutputStream out = activity.getContentResolver().openOutputStream(destination, "wt")) {
                if (out == null) throw new java.io.IOException("No writable document");
                byte[] buffer = new byte[32768];
                int count;
                while ((count = in.read(buffer)) != -1) out.write(buffer, 0, count);
                out.flush();
            } catch (Exception error) {
                failure = "文件未能完整保存，请重试或使用分段复制";
            }
            final String message = failure;
            activity.runOnUiThread(() -> finish(message == null, message));
        });
    }

    private void readSettings(Uri uri) {
        copying = true;
        worker.execute(() -> {
            byte[] bytes = null;
            try (InputStream in = activity.getContentResolver().openInputStream(uri)) {
                if (in != null) {
                    ByteArrayOutputStream output = new ByteArrayOutputStream();
                    byte[] buffer = new byte[4096];
                    int count;
                    while ((count = in.read(buffer)) != -1) {
                        if (output.size() + count > 64 * 1024) break;
                        output.write(buffer, 0, count);
                    }
                    if (count == -1) bytes = output.toByteArray();
                }
            } catch (Exception ignored) {
                // The provider may have revoked access while the picker was open.
            }
            final byte[] result = bytes;
            activity.runOnUiThread(() -> finish(result,
                result == null ? "无法读取设置文件，文件上限为 64 KiB" : null));
        });
    }

    private void finish(Object saved, String error) {
        copying = false;
        boolean opening = importing;
        importing = false;
        MethodChannel.Result reply = pending;
        pending = null;
        cleanup();
        if (destroyed || reply == null) return;
        if (error == null) reply.success(saved);
        else reply.error(opening ? "read" : "write", error, null);
    }
    private void cleanup() {
        if (staged != null) { staged.delete(); staged = null; }
    }
    void destroy() {
        destroyed = true;
        channel.setMethodCallHandler(null);
        worker.shutdown();
        // An active copy owns its file until its finally/completion path.
        if (!copying) { pending = null; cleanup(); }
    }
}
