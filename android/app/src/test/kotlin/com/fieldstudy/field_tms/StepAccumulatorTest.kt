package com.fieldstudy.field_tms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StepAccumulatorTest {
    private fun seconds(value: Long) = value * 1_000_000_000L

    @Test fun excludesBootHistoryAndPreStartSamples() {
        val steps = StepAccumulator()
        steps.resume(seconds(100))
        assertFalse(steps.accept(9000, seconds(90)))
        assertTrue(steps.accept(9010, seconds(101)))
        assertEquals(0, steps.steps)
        steps.accept(9014, seconds(104))
        assertEquals(4, steps.steps)
        assertTrue(steps.gap)
    }

    @Test fun excludesPausedWalkingAndRebasesOnResume() {
        val steps = StepAccumulator()
        steps.resume(seconds(1))
        steps.accept(0, seconds(1))
        steps.accept(8, seconds(5))
        steps.pause()
        assertFalse(steps.accept(50, seconds(20)))
        steps.resume(seconds(30))
        assertFalse(steps.accept(60, seconds(29)))
        steps.accept(63, seconds(31))
        steps.accept(66, seconds(33))
        assertEquals(11, steps.steps)
        assertTrue(steps.gap)
    }

    @Test fun duplicateStartDoesNotRebaseAnActiveWindow() {
        val steps = StepAccumulator()
        steps.resume(seconds(1))
        steps.accept(0, seconds(1))
        steps.resume(seconds(2))
        steps.accept(4, seconds(3))
        assertEquals(4, steps.steps)
        assertFalse(steps.gap)
    }

    @Test fun duplicateAndOutOfOrderSamplesDoNotDoubleCount() {
        val steps = StepAccumulator()
        steps.resume(seconds(1))
        steps.accept(0, seconds(1))
        steps.accept(5, seconds(4))
        assertFalse(steps.accept(5, seconds(4)))
        assertFalse(steps.accept(3, seconds(3)))
        steps.accept(8, seconds(6))
        assertEquals(8, steps.steps)
    }

    @Test fun counterResetNeverSubtractsOrSpikes() {
        val steps = StepAccumulator(20)
        steps.resume(seconds(100))
        steps.accept(10000, seconds(100))
        steps.accept(2, seconds(101))
        steps.accept(6, seconds(103))
        assertEquals(24, steps.steps)
        assertTrue(steps.gap)
    }

    @Test fun impossibleJumpIsOmittedAndNextDeltaCanRecover() {
        val steps = StepAccumulator()
        steps.resume(seconds(1))
        steps.accept(0, seconds(1))
        steps.accept(100000, seconds(2))
        steps.accept(100003, seconds(4))
        assertEquals(3, steps.steps)
        assertTrue(steps.gap)
    }

    @Test fun restoredTotalIsNotCombinedWithAnotherBootCounter() {
        val steps = StepAccumulator(418, initialGap = true)
        steps.resume(seconds(2))
        steps.accept(700000, seconds(3))
        assertEquals(418, steps.steps)
        steps.accept(700004, seconds(5))
        assertEquals(422, steps.steps)
    }
}
