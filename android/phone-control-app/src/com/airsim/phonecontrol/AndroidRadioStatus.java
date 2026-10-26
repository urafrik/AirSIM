package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.telephony.CellSignalStrength;
import android.telephony.ServiceState;
import android.telephony.SignalStrength;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;
import org.json.JSONObject;
import java.util.List;

/** Samples the default voice SIM. No IMEI, IMSI, ICCID or cell location is queried. */
final class AndroidRadioStatus {
    private AndroidRadioStatus() {}

    static JSONObject snapshot(Context context) throws Exception {
        JSONObject value = new JSONObject().put("signal_dbm", JSONObject.NULL)
                .put("network_mode", JSONObject.NULL).put("cellular_state", "unknown");
        TelephonyManager manager = context.getSystemService(TelephonyManager.class);
        if (manager == null) return value;
        try {
            int subscription = SubscriptionManager.getDefaultVoiceSubscriptionId();
            if (!SubscriptionManager.isValidSubscriptionId(subscription)) {
                subscription = SubscriptionManager.getDefaultDataSubscriptionId();
            }
            if (SubscriptionManager.isValidSubscriptionId(subscription)) {
                manager = manager.createForSubscriptionId(subscription);
            }
            value.put("operator", manager.getNetworkOperatorName());
            value.put("sim_inserted", manager.getSimState() == TelephonyManager.SIM_STATE_READY);
            if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                    != PackageManager.PERMISSION_GRANTED) return value;
            int network = manager.getDataNetworkType();
            if (network == TelephonyManager.NETWORK_TYPE_UNKNOWN) network = manager.getVoiceNetworkType();
            String preferred = preferredSignalType(network);
            value.put("network_mode", networkName(network));
            SignalStrength signal = manager.getSignalStrength();
            if (signal != null) {
                List<CellSignalStrength> cells = signal.getCellSignalStrengths();
                String[] types = new String[cells.size()];
                int[] dbms = new int[cells.size()];
                for (int i = 0; i < cells.size(); i++) {
                    types[i] = cells.get(i).getClass().getSimpleName();
                    dbms[i] = cells.get(i).getDbm();
                }
                Integer dbm = RadioSignalPolicy.select(preferred, types, dbms);
                if (dbm != null) value.put("signal_dbm", dbm);
            }
            try {
                ServiceState service = manager.getServiceState();
                if (service != null) value.put("cellular_state",
                        service.getState() == ServiceState.STATE_IN_SERVICE ? "registered"
                        : service.getState() == ServiceState.STATE_POWER_OFF ? "radio_off" : "no_service");
            } catch (SecurityException ignored) { /* Signal can still be available without location access. */ }
        } catch (SecurityException error) {
            // Missing/system-restricted permission is unknown signal, never fabricated full bars.
            value.put("signal_dbm", JSONObject.NULL);
        }
        return value;
    }

    private static String networkName(int type) {
        return switch (type) {
            case TelephonyManager.NETWORK_TYPE_NR -> "5G";
            case TelephonyManager.NETWORK_TYPE_LTE -> "4G";
            case TelephonyManager.NETWORK_TYPE_UMTS, TelephonyManager.NETWORK_TYPE_HSDPA,
                 TelephonyManager.NETWORK_TYPE_HSUPA, TelephonyManager.NETWORK_TYPE_HSPA,
                 TelephonyManager.NETWORK_TYPE_HSPAP, TelephonyManager.NETWORK_TYPE_TD_SCDMA,
                 TelephonyManager.NETWORK_TYPE_EVDO_0, TelephonyManager.NETWORK_TYPE_EVDO_A,
                 TelephonyManager.NETWORK_TYPE_EVDO_B, TelephonyManager.NETWORK_TYPE_EHRPD -> "3G";
            case TelephonyManager.NETWORK_TYPE_GPRS, TelephonyManager.NETWORK_TYPE_EDGE,
                 TelephonyManager.NETWORK_TYPE_GSM, TelephonyManager.NETWORK_TYPE_CDMA,
                 TelephonyManager.NETWORK_TYPE_1xRTT -> "2G";
            default -> "未知";
        };
    }

    private static String preferredSignalType(int type) {
        return switch (type) {
            case TelephonyManager.NETWORK_TYPE_NR -> "CellSignalStrengthNr";
            case TelephonyManager.NETWORK_TYPE_LTE -> "CellSignalStrengthLte";
            case TelephonyManager.NETWORK_TYPE_GPRS, TelephonyManager.NETWORK_TYPE_EDGE,
                 TelephonyManager.NETWORK_TYPE_GSM -> "CellSignalStrengthGsm";
            case TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "CellSignalStrengthTdscdma";
            case TelephonyManager.NETWORK_TYPE_CDMA, TelephonyManager.NETWORK_TYPE_1xRTT,
                 TelephonyManager.NETWORK_TYPE_EVDO_0, TelephonyManager.NETWORK_TYPE_EVDO_A,
                 TelephonyManager.NETWORK_TYPE_EVDO_B, TelephonyManager.NETWORK_TYPE_EHRPD -> "CellSignalStrengthCdma";
            default -> "CellSignalStrengthWcdma";
        };
    }
}
