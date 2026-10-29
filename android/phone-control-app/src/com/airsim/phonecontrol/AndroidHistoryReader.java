package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.provider.CallLog;
import android.provider.Settings;
import android.provider.Telephony;
import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;

/** Read-only, authenticated system history export. Does not touch the delivery queue/cursor. */
final class AndroidHistoryReader {
    private final Context context;
    AndroidHistoryReader(Context context) { this.context = context; }

    JSONObject status() throws Exception {
        return new JSONObject().put("supported", true)
                .put("sms_allowed", allowed(Manifest.permission.READ_SMS))
                .put("calls_allowed", allowed(Manifest.permission.READ_CALL_LOG));
    }
    private boolean allowed(String permission) {
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }

    JSONObject page(JSONObject input) throws Exception {
        String kind = input.optString("kind");
        if (!kind.equals("sms") && !kind.equals("calls")) throw new IllegalArgumentException("记录类型无效");
        boolean sms = kind.equals("sms");
        if (!allowed(sms ? Manifest.permission.READ_SMS : Manifest.permission.READ_CALL_LOG)) {
            throw new SecurityException("请在安卓 AirSIM 设置中点击“授权历史记录读取”，允许读取" + (sms ? "短信" : "通话记录"));
        }
        long start = input.optLong("start_ms", 0), end = input.optLong("end_ms", Long.MAX_VALUE);
        long after = input.optLong("after_id", 0), upper = input.optLong("snapshot_max_id", 0);
        if (start < 0 || end <= start || after < 0 || upper < 0 || (upper > 0 && after > upper)) {
            throw new IllegalArgumentException("日期范围或分页游标无效");
        }
        Uri uri = sms ? Telephony.Sms.CONTENT_URI : CallLog.Calls.CONTENT_URI;
        // Pin the upper row ID once, so new arrivals do not prolong an 'all' import forever.
        if (upper == 0) {
            try (Cursor cursor = context.getContentResolver().query(uri, new String[]{"_id"}, null, null, "_id DESC")) {
                if (cursor == null) throw new IllegalStateException("安卓系统未返回历史记录");
                if (cursor.moveToFirst()) upper = cursor.getLong(0);
            }
        }
        JSONArray messages = new JSONArray(), calls = new JSONArray();
        if (upper == 0) return result(messages, calls, after, upper, false);
        String[] projection = sms ? new String[]{"_id", "address", "body", "date", "date_sent", "type", "read"}
                : new String[]{"_id", "number", "date", "duration", "type"};
        String selection = "_id > ? AND _id <= ? AND date >= ? AND date < ?";
        if (sms) selection += " AND type IN (1, 2)"; // received and sent; never drafts/outbox
        String[] args = {Long.toString(after), Long.toString(upper), Long.toString(start), Long.toString(end)};
        boolean more = false;
        int count = 0, bytes = 0;
        String device = deviceKey();
        try (Cursor cursor = context.getContentResolver().query(uri, projection, selection, args, "_id ASC")) {
            if (cursor == null) throw new IllegalStateException("安卓系统未返回历史记录");
            while (cursor.moveToNext()) {
                if (count >= 100 || bytes >= 256_000) { more = true; break; }
                long row = cursor.getLong(0);
                JSONObject record = sms ? sms(cursor, device, row) : call(cursor, device, row);
                (sms ? messages : calls).put(record);
                bytes += record.toString().getBytes(StandardCharsets.UTF_8).length;
                count++;
                after = row;
            }
        }
        return result(messages, calls, after, upper, more);
    }

    private JSONObject result(JSONArray messages, JSONArray calls, long next, long upper, boolean more) throws Exception {
        return new JSONObject().put("messages", messages).put("calls", calls)
                .put("next_id", next).put("snapshot_max_id", upper).put("has_more", more);
    }
    private JSONObject sms(Cursor c, String device, long row) throws Exception {
        String sender = c.isNull(1) ? "" : c.getString(1), body = c.isNull(2) ? "" : c.getString(2);
        long date = Math.max(0, c.getLong(3)), sent = c.getLong(4);
        boolean outgoing = c.getInt(5) == 2;
        String source = "android-history-" + device + "-sms-" + row;
        long timestamp = SMSDeliveryIdentity.providerTimestamp(sent, date);
        JSONObject value = new JSONObject().put("sender", sender).put("content", body)
                .put("timestamp", Instant.ofEpochMilli(Math.max(0, timestamp)).toString())
                .put("direction", outgoing ? "outgoing" : "incoming")
                .put("android_history_id", source).put("source_read", c.getInt(6) != 0)
                .put("delivery_id", outgoing ? source : SMSDeliveryIdentity.id(sender, body, timestamp));
        if (!outgoing) value.put("received_at", Instant.ofEpochMilli(date).toString());
        return value;
    }
    private JSONObject call(Cursor c, String device, long row) throws Exception {
        long date = Math.max(0, c.getLong(2)), duration = Math.max(0, c.getLong(3));
        int type = c.getInt(4);
        String source = "android-history-" + device + "-call-" + row;
        String systemType = switch (type) {
            case 1 -> "incoming"; case 2 -> "outgoing"; case 3 -> "missed";
            case 4 -> "voicemail"; case 5 -> "rejected"; case 6 -> "blocked";
            case 7 -> "answered_elsewhere"; default -> "unknown";
        };
        JSONObject value = new JSONObject().put("id", source).put("index", 0)
                .put("direction", type == 2 ? "outgoing" : "incoming").put("state", "ended")
                .put("number", c.isNull(1) ? JSONObject.NULL : c.getString(1))
                .put("started_at", Instant.ofEpochMilli(date).toString())
                .put("updated_at", Instant.ofEpochMilli(date).toString())
                .put("missed", type == 3).put("android_history_id", source)
                .put("system_call_type", systemType).put("duration_seconds", duration);
        if (duration > 0 || type == 1 || type == 7) value.put("was_connected", true);
        else if (type == 3 || type == 5 || type == 6) value.put("was_connected", false);
        // An outgoing zero-second row cannot prove whether a very short call connected.
        return value;
    }
    private String deviceKey() throws Exception {
        String id = Settings.Secure.getString(context.getContentResolver(), Settings.Secure.ANDROID_ID);
        byte[] hash = MessageDigest.getInstance("SHA-256").digest((id == null ? context.getPackageName() : id).getBytes(StandardCharsets.UTF_8));
        StringBuilder key = new StringBuilder();
        for (int i = 0; i < 8; i++) key.append(String.format(java.util.Locale.ROOT, "%02x", hash[i] & 255));
        return key.toString();
    }
}
