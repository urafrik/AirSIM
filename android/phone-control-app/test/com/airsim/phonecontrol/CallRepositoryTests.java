package com.airsim.phonecontrol;

import android.telecom.Call;

public final class CallRepositoryTests {
    public static void main(String[] args) {
        answerNeverTargetsAnActiveCallWithoutRinging();
        cloudRejectTargetsOnlyItsAuthenticatedCall();
        localRejectUsesPublishedCallIdentity();
        repeatedHangupCannotDisconnectANewerCall();
        System.out.println("call repository tests passed");
    }

    private static void answerNeverTargetsAnActiveCallWithoutRinging() {
        Call active = new Call(Call.STATE_ACTIVE);
        Call ringing = new Call(Call.STATE_RINGING);
        String activeID = CallRepository.add(active);
        String ringingID = CallRepository.add(ringing);
        try {
            assertEquals(ringingID, CallRepository.idForAction("answer"));
            CallRepository.remove(ringing);
            assertEquals("", CallRepository.idForAction("answer"));
            assertEquals(activeID, CallRepository.idForAction("end"));
        } finally {
            CallRepository.remove(ringing);
            CallRepository.remove(active);
        }
    }

    private static void cloudRejectTargetsOnlyItsAuthenticatedCall() {
        Call other = new Call(Call.STATE_RINGING);
        Call target = new Call(Call.STATE_RINGING);
        String otherID = CallRepository.add(other);
        String targetID = CallRepository.add(target);
        try {
            CloudCallTarget identity = new CloudCallTarget(
                    "relay-call-7", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 3, targetID);
            String selected = identity.resolve(
                    "relay-call-7", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 3);
            assertEquals(targetID, selected);
            CallRepository.ActionResult result = CallRepository.execute(
                    new AgentCommand("command-7", "reject", selected, ""), null);
            assertTrue(result.success);
            assertEquals(Integer.toString(Call.STATE_DISCONNECTED), Integer.toString(target.getState()));
            assertEquals(Integer.toString(Call.STATE_RINGING), Integer.toString(other.getState()));
            assertEquals("", identity.resolve(
                    "relay-call-previous", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 3));
            assertEquals("", identity.resolve(
                    "relay-call-7", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 2));
        } finally {
            CallRepository.remove(target);
            CallRepository.remove(other);
        }
    }

    private static void localRejectUsesPublishedCallIdentity() {
        Call other = new Call(Call.STATE_RINGING);
        Call target = new Call(Call.STATE_RINGING);
        String otherID = CallRepository.add(other);
        String targetID = CallRepository.add(target);
        try {
            String selected = CallRepository.idForPublishedAction(
                    "reject", "visible-target", "visible-target", targetID);
            assertEquals(targetID, selected);
            assertTrue(CallRepository.execute(
                    new AgentCommand("local-reject", "reject", selected, ""), null).success);
            assertEquals(Integer.toString(Call.STATE_DISCONNECTED), Integer.toString(target.getState()));
            assertEquals(Integer.toString(Call.STATE_RINGING), Integer.toString(other.getState()));
            assertEquals("", CallRepository.idForPublishedAction(
                    "reject", "stale-visible-call", "visible-target", targetID));
            assertEquals("", CallRepository.idForPublishedAction(
                    "answer", "visible-target", "visible-target", targetID));
        } finally {
            CallRepository.remove(target);
            CallRepository.remove(other);
        }
    }

    private static void repeatedHangupCannotDisconnectANewerCall() {
        Call ended = new Call(Call.STATE_ACTIVE);
        String endedID = CallRepository.add(ended);
        CallRepository.remove(ended);
        Call newer = new Call(Call.STATE_ACTIVE);
        String newerID = CallRepository.add(newer);
        try {
            assertTrue(CallRepository.execute(new AgentCommand("repeat", "end", endedID, ""), null).success);
            assertTrue(!CallRepository.execute(new AgentCommand("unknown", "end", "unknown-id", ""), null).success);
            assertEquals(Integer.toString(Call.STATE_ACTIVE), Integer.toString(newer.getState()));
            assertEquals(endedID, CallRepository.idForPublishedAction("end", "old", "old", endedID));
            assertEquals("", CallRepository.idForPublishedAction("end", "old", "new", newerID));
        } finally { CallRepository.remove(newer); }
    }

    private static void assertTrue(boolean value) {
        if (!value) throw new AssertionError("expected true");
    }

    private static void assertEquals(String expected, String actual) {
        if (!expected.equals(actual)) {
            throw new AssertionError("expected <" + expected + "> but was <" + actual + ">");
        }
    }
}
