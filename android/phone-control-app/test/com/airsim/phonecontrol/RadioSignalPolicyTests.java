package com.airsim.phonecontrol;

public final class RadioSignalPolicyTests {
    public static void main(String[] args) {
        check(RadioSignalPolicy.select("CellSignalStrengthNr",
                new String[]{"CellSignalStrengthLte", "CellSignalStrengthNr"},
                new int[]{-83, -105}), -105);
        check(RadioSignalPolicy.select("CellSignalStrengthLte",
                new String[]{"CellSignalStrengthNr", "CellSignalStrengthLte"},
                new int[]{Integer.MAX_VALUE, -98}), -98);
        check(RadioSignalPolicy.select("CellSignalStrengthNr",
                new String[]{"CellSignalStrengthLte"}, new int[]{-91}), -91);
        check(RadioSignalPolicy.select("CellSignalStrengthNr",
                new String[]{"unknown", "unknown", "unknown"}, new int[]{0, -1, Integer.MAX_VALUE}), null);
        check(RadioSignalPolicy.select("none", new String[]{}, new int[]{}), null);
        System.out.println("PASS radio signal selection: RAT priority, unavailable signal and fallback");
    }

    private static void check(Integer actual, Integer expected) {
        if (!java.util.Objects.equals(actual, expected)) throw new AssertionError(actual + " != " + expected);
    }
}
