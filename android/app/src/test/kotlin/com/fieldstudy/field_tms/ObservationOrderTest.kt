package com.fieldstudy.field_tms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class ObservationOrderTest {
    @Test fun capturesAreStrictlyOrderedAcrossUnchangedMeasurementsAndSessionSwitches() {
        val order = ObservationOrder(newEpoch = { "owner-a" })
        val first = order.next()
        val methodReply = order.next()
        val laterEvent = order.next()
        assertEquals("owner-a", first.epoch)
        assertEquals(first.epoch, laterEvent.epoch)
        assertEquals(1L, first.sequence)
        assertEquals(2L, methodReply.sequence)
        assertEquals(3L, laterEvent.sequence)
    }

    @Test fun newOwnerDoesNotRestoreThePreviousOwnersSequence() {
        val beforeRestart = ObservationOrder(newEpoch = { "owner-a" })
        beforeRestart.next()
        val saved = beforeRestart.next()
        val restarted = ObservationOrder(newEpoch = { "owner-b" }).next()
        assertNotEquals(saved.epoch, restarted.epoch)
        assertEquals(1L, restarted.sequence)
    }

    @Test fun portableIntegerLimitRotatesOwnerWithoutWrappingWithinEpoch() {
        var epoch = 0
        val order = ObservationOrder(
            newEpoch = { "owner-${++epoch}" },
            initialSequence = ObservationOrder.MAX_SEQUENCE - 1L,
        )
        val last = order.next()
        val rotated = order.next()
        assertEquals(ObservationOrder.MAX_SEQUENCE, last.sequence)
        assertNotEquals(last.epoch, rotated.epoch)
        assertEquals(1L, rotated.sequence)
    }
}
