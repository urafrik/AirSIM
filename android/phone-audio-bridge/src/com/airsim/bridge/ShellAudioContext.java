package com.airsim.bridge;

import android.app.Application;
import android.content.Context;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.os.Looper;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/** Supplies the application required by some OEM audio start hooks in app_process. */
final class ShellAudioContext {
    private ShellAudioContext() {}

    static synchronized void start(AudioRecord recorder, AudioTrack track) throws Exception {
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Object existing = activityThread.getMethod("currentApplication").invoke(null);
        if (existing != null) {
            recorder.startRecording();
            track.play();
            return;
        }
        if (Looper.myLooper() == null) {
            if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
            else Looper.prepare();
        }
        Object thread = activityThread.getMethod("currentActivityThread").invoke(null);
        Object previousThread = thread;
        if (thread == null) thread = activityThread.getMethod("systemMain").invoke(null);
        Context system = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
        Context shell = system.createPackageContext("com.android.shell", 0);
        Application application = new Application();
        Method attach = Application.class.getDeclaredMethod("attach", Context.class);
        attach.setAccessible(true);
        attach.invoke(application, shell);
        Field initialApplication = activityThread.getDeclaredField("mInitialApplication");
        initialApplication.setAccessible(true);
        Object previous = initialApplication.get(thread);
        try {
            initialApplication.set(thread, application);
            recorder.startRecording();
            track.play();
        } finally {
            // Keep later AudioRecord constructors using app_process's original attribution.
            initialApplication.set(thread, previous);
            if (previousThread == null) {
                Field currentThread = activityThread.getDeclaredField("sCurrentActivityThread");
                currentThread.setAccessible(true);
                currentThread.set(null, null);
            }
        }
    }
}
