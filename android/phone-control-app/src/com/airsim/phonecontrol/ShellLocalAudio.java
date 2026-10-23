package com.airsim.phonecontrol;

import android.content.Context;
import android.media.AudioManager;

/** Runs with the existing Shizuku shell identity and restores the user's audio state. */
final class ShellLocalAudio {
    private AudioManager audio;
    private boolean cycle;
    private boolean previousMicrophoneMuted;
    private boolean previousOutputMuted;

    private AudioManager manager() throws Exception {
        if (audio == null) {
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Object thread = activityThread.getMethod("currentActivityThread").invoke(null);
            if (thread == null) throw new IllegalStateException("Shizuku application context unavailable");
            Context system = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
            Context shell = system.createPackageContext("com.android.shell", 0);
            audio = (AudioManager) shell.getSystemService(Context.AUDIO_SERVICE);
            if (audio == null) throw new IllegalStateException("audio service unavailable");
        }
        return audio;
    }

    synchronized String setMuted(boolean muted) throws Exception {
        AudioManager manager = manager();
        if (muted && !cycle) {
            previousMicrophoneMuted = manager.isMicrophoneMute();
            previousOutputMuted = manager.isStreamMute(AudioManager.STREAM_VOICE_CALL);
            cycle = true;
        }
        if (muted) {
            manager.setMicrophoneMute(true);
            manager.adjustStreamVolume(AudioManager.STREAM_VOICE_CALL, AudioManager.ADJUST_MUTE, 0);
            if (!manager.isMicrophoneMute() || !manager.isStreamMute(AudioManager.STREAM_VOICE_CALL)) {
                throw new IllegalStateException("system did not apply local microphone/output mute");
            }
            return "local_audio_muted microphone_muted=true output_muted=true";
        }
        if (cycle) {
            manager.setMicrophoneMute(previousMicrophoneMuted);
            manager.adjustStreamVolume(AudioManager.STREAM_VOICE_CALL,
                    previousOutputMuted ? AudioManager.ADJUST_MUTE : AudioManager.ADJUST_UNMUTE, 0);
            if (manager.isMicrophoneMute() != previousMicrophoneMuted
                    || manager.isStreamMute(AudioManager.STREAM_VOICE_CALL) != previousOutputMuted) {
                throw new IllegalStateException("system did not restore local microphone/output state");
            }
            cycle = false;
        }
        return "local_audio_restored verified=true";
    }
}
