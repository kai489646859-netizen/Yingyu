package com.yingyu.player;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.os.Build;
import java.lang.ref.WeakReference;

public final class UpdateInstallReceiver extends BroadcastReceiver {
    static volatile String state = "idle";
    private static volatile int session = -1;
    private static WeakReference<AppUpdateBridge> bridge = new WeakReference<>(null);
    private static WeakReference<Activity> current = new WeakReference<>(null);
    private static Intent pendingConfirmation;

    static void resume(Activity activity) {
        current = new WeakReference<>(activity);
        present();
    }

    static void bind(AppUpdateBridge target) { bridge = new WeakReference<>(target); }
    static void unbind(AppUpdateBridge target) {
        if (bridge.get() == target) bridge.clear();
    }

    static void committing(int id) { session = id; state = "waiting"; }
    static void failed(int id) {
        if (session != -1 && session != id) return;
        session = -1;
        publish("failed");
    }

    private static void publish(String next) {
        state = next;
        AppUpdateBridge target = bridge.get();
        if (target != null) target.installationChanged(next);
    }

    static void pause(Activity activity) {
        if (current.get() == activity) current.clear();
    }

    private static void present() {
        Activity activity = current.get();
        if (activity == null || activity.isFinishing() || pendingConfirmation == null) return;
        try {
            activity.startActivity(pendingConfirmation);
            pendingConfirmation = null;
            publish("confirming");
        } catch (RuntimeException failure) {
            pendingConfirmation = null;
            publish("failed");
        }
    }

    @Override @SuppressWarnings("deprecation")
    public void onReceive(Context context, Intent intent) {
        if (!(context.getPackageName() + ".INSTALL_RESULT").equals(intent.getAction())) return;
        int id = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1);
        if (id < 0 || (session != -1 && id != session)) return;
        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            pendingConfirmation = Build.VERSION.SDK_INT >= 33
                ? intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent.class)
                : intent.getParcelableExtra(Intent.EXTRA_INTENT);
            session = id;
            publish(pendingConfirmation == null ? "failed" : "waiting");
            present();
        } else {
            pendingConfirmation = null;
            session = -1;
            publish(status == PackageInstaller.STATUS_SUCCESS ? "installed"
                : status == PackageInstaller.STATUS_FAILURE_ABORTED ? "cancelled" : "failed");
        }
    }
}
