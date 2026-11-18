package com.yingyu.player;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import java.util.HashMap;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/** Projects the current Flutter playback owner onto Android system controls. */
final class MediaControlBridge {
    private static final int ID = 5710;
    private static final String CHANNEL = "yingyu.playback";
    private final MainActivity activity;
    private final MethodChannel channel;
    private final NotificationManager notifications;
    private final String action;
    private MediaSession session;
    private long owner = -1;
    private long duration;
    private String title;
    private String mode;
    private boolean interactive;
    private final BroadcastReceiver controls = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (action.equals(intent.getAction())) {
                dispatch(intent.getLongExtra("owner", -1), intent.getStringExtra("control"), -1);
            }
        }
    };

    MediaControlBridge(MainActivity activity, FlutterEngine engine) {
        this.activity = activity;
        action = activity.getPackageName() + ".MEDIA_CONTROL";
        notifications = activity.getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel(
            CHANNEL, "映屿播放控制", NotificationManager.IMPORTANCE_LOW));
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(
            controls, new IntentFilter(action), Context.RECEIVER_NOT_EXPORTED);
        else activity.registerReceiver(controls, new IntentFilter(action),
            activity.getPackageName() + ".INTERNAL_MEDIA_CONTROL", null);
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "yingyu/media-control");
        channel.setMethodCallHandler((call, result) -> {
            Number id = call.argument("owner");
            if (id == null) { result.error("owner", "缺少播放控制标识", null); return; }
            if ("clear".equals(call.method)) {
                if (id.longValue() >= owner) {
                    owner = id.longValue();
                    clear();
                }
                result.success(null);
            } else if ("state".equals(call.method)) {
                try {
                    if (id.longValue() >= owner) update(id.longValue(),
                        call.argument("title"), call.argument("mode"),
                        call.argument("position"), call.argument("duration"),
                        call.argument("speed"), Boolean.TRUE.equals(call.argument("interactive")));
                    result.success(null);
                } catch (RuntimeException failure) {
                    clear();
                    result.error("media-control", "无法显示系统媒体控制", null);
                }
            } else result.notImplemented();
        });
    }

    private void dispatch(long target, String command, long position) {
        if (session == null || owner != target || command == null) return;
        if (!interactive && !"stop".equals(command)) return;
        HashMap<String, Object> event = new HashMap<>();
        event.put("owner", target);
        event.put("command", command);
        event.put("position", position);
        channel.invokeMethod("command", event);
    }

    private void update(long id, String name, String state, Number position, Number length,
            Number speed, boolean enabled) {
        if (session == null || owner != id) {
            clear();
            owner = id;
            session = new MediaSession(activity, "Yingyu");
            session.setCallback(new MediaSession.Callback() {
                @Override public void onPlay() { dispatch(id, "play", -1); }
                @Override public void onPause() { dispatch(id, "pause", -1); }
                @Override public void onStop() { dispatch(id, "stop", -1); }
                @Override public void onSeekTo(long target) { dispatch(id, "seek", target); }
            }, new Handler(Looper.getMainLooper()));
        }
        long total = Math.max(0, length.longValue());
        boolean redraw = !name.equals(title) || !state.equals(mode)
            || interactive != enabled || (total > 0) != (duration > 0);
        if (!name.equals(title) || total != duration) {
            session.setMetadata(new MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, name)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, total).build());
        }
        title = name;
        mode = state;
        duration = total;
        interactive = enabled;
        int playback = switch (state) {
            case "playing" -> PlaybackState.STATE_PLAYING;
            case "buffering" -> PlaybackState.STATE_BUFFERING;
            default -> PlaybackState.STATE_PAUSED;
        };
        long actions = PlaybackState.ACTION_STOP;
        if (enabled) actions |= PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE
            | PlaybackState.ACTION_PLAY_PAUSE | (total > 0 ? PlaybackState.ACTION_SEEK_TO : 0);
        session.setPlaybackState(new PlaybackState.Builder().setActions(actions)
            .setState(playback, Math.max(0, position.longValue()),
                playback == PlaybackState.STATE_PLAYING ? speed.floatValue() : 0).build());
        if (!session.isActive()) session.setActive(true);
        if (!redraw) return;
        Intent reopen = new Intent(activity, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent content = PendingIntent.getActivity(activity, 0, reopen, PendingIntent.FLAG_IMMUTABLE);
        session.setSessionActivity(content);
        Notification.Builder notice = new Notification.Builder(activity, CHANNEL)
            .setContentTitle(name)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(content)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE);
        Notification.MediaStyle style = new Notification.MediaStyle().setMediaSession(session.getSessionToken());
        if (enabled) {
            boolean pause = playback != PlaybackState.STATE_PAUSED;
            notice.addAction(button(id, pause ? "pause" : "play", pause ? "暂停" : "播放",
                pause ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play));
        }
        notice.addAction(button(id, "stop", "停止", android.R.drawable.ic_menu_close_clear_cancel));
        style.setShowActionsInCompactView(enabled ? new int[]{0, 1} : new int[]{0});
        notifications.notify(ID, notice.setStyle(style).build());
    }

    private Notification.Action button(long id, String command, String label, int icon) {
        Intent intent = new Intent(action).setPackage(activity.getPackageName())
            .setData(Uri.parse("yingyu-media://" + id + "/" + command))
            .putExtra("owner", id).putExtra("control", command);
        return new Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(activity, icon), label,
            PendingIntent.getBroadcast(activity, 0, intent, PendingIntent.FLAG_IMMUTABLE)).build();
    }

    private void clear() {
        if (session != null) { session.release(); session = null; }
        notifications.cancel(ID);
        title = mode = null;
        duration = 0;
        interactive = false;
    }

    void close() {
        clear();
        activity.unregisterReceiver(controls);
        channel.setMethodCallHandler(null);
    }
}
