package com.airsim.bridge;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

/** Confirms the actual active session when an OEM's AudioTrack route API is stale. */
final class ShellAudioPolicyRoute {
    private ShellAudioPolicyRoute() {}

    static boolean verify(int sessionId, int deviceId) {
        Process process = null;
        try {
            process = new ProcessBuilder("/system/bin/dumpsys", "media.audio_policy")
                    .redirectErrorStream(true).start();
            Process active = process;
            StringBuilder output = new StringBuilder();
            Thread reader = new Thread(() -> {
                try (BufferedReader input = new BufferedReader(new InputStreamReader(
                        active.getInputStream(), StandardCharsets.UTF_8))) {
                    String line;
                    while ((line = input.readLine()) != null) {
                        if (output.length() < 1_048_576) output.append(line).append('\n');
                    }
                } catch (Exception ignored) {}
            }, "airsim-policy-route");
            reader.setDaemon(true);
            reader.start();
            if (!process.waitFor(2, TimeUnit.SECONDS)) return false;
            reader.join(500);
            return !reader.isAlive() && process.exitValue() == 0
                    && matches(output.toString(), sessionId, deviceId);
        } catch (Exception error) {
            if (error instanceof InterruptedException) Thread.currentThread().interrupt();
            return false;
        } finally {
            if (process != null) process.destroy();
        }
    }

    static boolean matches(String policy, int sessionId, int deviceId) {
        if (sessionId <= 0 || deviceId <= 0) return false;
        boolean telephony = false;
        boolean matchingClient = false;
        Pattern client = Pattern.compile(".*Session ID: " + sessionId
                + "; uid 2000; State: Active\\s*");
        for (String line : policy.split("\\R")) {
            if (line.matches("\\s*Inputs \\(.*")) break;
            if (line.matches("  \\d+\\. Port ID: .*")) {
                telephony = false;
                matchingClient = false;
            }
            if (line.contains("Devices: {AUDIO_DEVICE_OUT_TELEPHONY_TX")) telephony = true;
            if (line.contains("Session ID:")) matchingClient = telephony && client.matcher(line).matches();
            if (matchingClient && line.trim().equals("Preferred Device Port ID: " + deviceId + ";")) return true;
        }
        return false;
    }
}
