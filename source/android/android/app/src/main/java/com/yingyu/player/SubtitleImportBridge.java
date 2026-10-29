package com.yingyu.player;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import java.io.Closeable;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/** Only the user-chosen document. No storage permissions or media scanning. */
final class SubtitleImportBridge {
    static final int REQUEST = 7105;
    private final Activity activity;
    private final MethodChannel channel;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Set<File> owned = new HashSet<>();
    private MethodChannel.Result pending;
    private volatile boolean destroyed;
    private volatile Closeable input;

    SubtitleImportBridge(Activity activity, FlutterEngine engine) {
        this.activity = activity;
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/subtitle-import");
        channel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "pick":
                        if (pending != null) { result.error("busy", "已有字幕正在导入", null); return; }
                        pending = result;
                        activity.startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"), REQUEST);
                        return;
                    case "release":
                        File selected = new File((String) call.arguments).getCanonicalFile();
                        if (owned.remove(selected)) selected.delete();
                        result.success(null); return;
                    default: result.notImplemented();
                }
            } catch (Exception error) {
                if (pending == result) pending = null;
                result.error("subtitle", "无法打开字幕文件，请重试", null);
            }
        });
    }

    void result(int resultCode, Intent data) {
        if (pending == null || destroyed) return;
        Uri uri = data == null ? null : data.getData();
        if (resultCode != Activity.RESULT_OK || uri == null) {
            MethodChannel.Result reply = pending; pending = null; reply.success(null); return;
        }
        worker.execute(() -> {
            File file = null;
            HashMap<String, Object> value = null;
            try {
                String name = null;
                long size = -1;
                try (Cursor cursor = activity.getContentResolver().query(uri,
                        new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}, null, null, null)) {
                    if (cursor != null && cursor.moveToFirst()) {
                        int n = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME), s = cursor.getColumnIndex(OpenableColumns.SIZE);
                        if (n >= 0) name = cursor.getString(n);
                        if (s >= 0 && !cursor.isNull(s)) size = cursor.getLong(s);
                    }
                }
                if (destroyed || name == null || size > SubtitleCopy.MAX) throw new java.io.IOException("Invalid size");
                int dot = name.lastIndexOf('.');
                String extension = dot < 0 ? "" : name.substring(dot + 1).toLowerCase(Locale.ROOT);
                if (!(extension.equals("srt") || extension.equals("ass") || extension.equals("ssa") || extension.equals("vtt") || extension.equals("sup"))) throw new java.io.IOException("Unsupported subtitle");
                file = File.createTempFile("yingyu-import-subtitle-", "." + extension, activity.getCacheDir()).getCanonicalFile();
                try (InputStream in = activity.getContentResolver().openInputStream(uri);
                     FileOutputStream out = new FileOutputStream(file)) {
                    if (in == null) throw new java.io.IOException("No readable document");
                    input = in;
                    if (destroyed) throw new java.io.IOException("Cancelled");
                    SubtitleCopy.copy(in, out, SubtitleCopy.MAX);
                } finally { input = null; }
                if (destroyed) throw new java.io.IOException("Cancelled");
                value = new HashMap<>();
                value.put("path", file.getAbsolutePath());
                value.put("name", name.replaceAll("[\\p{Cntrl}]", " ").substring(0, Math.min(name.length(), 240)));
                value.put("codec", extension.equals("sup") ? "hdmv_pgs_subtitle" : extension);
            } catch (Exception error) {
                if (file != null) file.delete();
            }
            final File selected = file;
            final HashMap<String, Object> result = value;
            activity.runOnUiThread(() -> {
                MethodChannel.Result reply = pending; pending = null;
                if (destroyed || reply == null) { if (selected != null) selected.delete(); return; }
                if (result == null) reply.error("read", "未能导入字幕，请选择不超过 64 MiB 的 SRT、ASS、SSA、VTT 或 SUP 文件", null);
                else { owned.add(selected); reply.success(result); }
            });
        });
    }

    void destroy() {
        destroyed = true;
        channel.setMethodCallHandler(null);
        pending = null;
        Closeable stream = input;
        if (stream != null) { try { stream.close(); } catch (Exception ignored) {} }
        worker.shutdownNow();
        // A running copy cleans its file in its completion path. Completed
        // files have been released by their sessions or die with this engine.
        for (File file : owned) file.delete();
        owned.clear();
    }
}
