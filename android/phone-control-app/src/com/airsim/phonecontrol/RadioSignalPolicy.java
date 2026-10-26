package com.airsim.phonecontrol;

final class RadioSignalPolicy {
    private RadioSignalPolicy() {}

    static boolean valid(int dbm) { return dbm >= -160 && dbm <= -20; }

    static Integer select(String preferredType, String[] types, int[] dbms) {
        Integer fallback = null;
        for (int i = 0; i < Math.min(types.length, dbms.length); i++) {
            if (!valid(dbms[i])) continue;
            if (fallback == null) fallback = dbms[i];
            if (types[i].equals(preferredType)) return dbms[i];
        }
        return fallback;
    }
}
