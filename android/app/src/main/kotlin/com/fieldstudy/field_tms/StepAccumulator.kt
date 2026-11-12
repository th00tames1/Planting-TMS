package com.fieldstudy.field_tms

/** Boot-counter differences for active windows, independent of Android APIs. */
internal class StepAccumulator(initialSteps: Long = 0, initialGap: Boolean = false) {
    var steps: Long = initialSteps.coerceAtLeast(0)
        private set
    var gap: Boolean = initialGap
        private set
    var active = false
        private set
    var hasBaseline = false
        private set
    private var windowStartNs = 0L
    private var lastCounter = 0L
    private var lastTimestampNs = 0L

    fun resume(atNs: Long) {
        if (active) return
        active = true
        hasBaseline = false
        windowStartNs = atNs
    }

    fun pause() {
        // A delayed counter batch cannot be divided precisely at a pause.
        if (active && hasBaseline) gap = true
        active = false
        hasBaseline = false
    }

    fun markGap() { gap = true }

    fun accept(counter: Long, timestampNs: Long): Boolean {
        if (!active || timestampNs < windowStartNs) return false
        if (counter < 0 || timestampNs < 0) {
            gap = true
            return false
        }
        if (!hasBaseline) {
            lastCounter = counter
            lastTimestampNs = timestampNs
            hasBaseline = true
            // Discard the first fresh batch: it can include pre-start steps.
            if (counter > 0) gap = true
            return true
        }
        if (timestampNs <= lastTimestampNs) return false
        val delta = counter - lastCounter
        val seconds = (timestampNs - lastTimestampNs) / 1_000_000_000.0
        lastCounter = counter
        lastTimestampNs = timestampNs
        // A reset, discontinuity or impossible burst is rebased, never added.
        if (delta < 0 || delta > 20.0 + seconds * 10.0 || steps > Long.MAX_VALUE - delta) {
            gap = true
            return true
        }
        steps += delta
        return true
    }
}
