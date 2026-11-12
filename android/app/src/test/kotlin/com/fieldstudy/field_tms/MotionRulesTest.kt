package com.fieldstudy.field_tms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MotionRulesTest {
    @Test fun pauseDoesNotTurnPermissionDenialIntoReadiness() {
        assertEquals("permissionDenied", MotionRules.pausedStatus("permissionDenied", true, false))
        assertEquals("permissionDenied", MotionRules.pausedStatus("running", true, false))
    }

    @Test fun pausePreservesFailureButAllowsAHealthySessionToPause() {
        assertEquals("error", MotionRules.pausedStatus("error", true, true))
        assertEquals("unavailable", MotionRules.pausedStatus("unavailable", false, true))
        assertEquals("paused", MotionRules.pausedStatus("running", true, true))
    }

    @Test fun failureOrMissingSensorNeverExposesDistance() {
        for (status in listOf("unavailable", "error", "permissionDenied")) {
            assertNull(MotionRules.distance(status, true, 100, 0.75))
        }
        assertNull(MotionRules.distance("paused", false, 100, 0.75))
    }

    @Test fun distanceRequiresCalibrationAndUsesSessionStepsOnly() {
        assertNull(MotionRules.distance("running", true, 100, null))
        assertEquals(75.0, MotionRules.distance("running", true, 100, 0.75)!!, 0.0)
        assertEquals(75.0, MotionRules.distance("paused", true, 100, 0.75)!!, 0.0)
    }
}
