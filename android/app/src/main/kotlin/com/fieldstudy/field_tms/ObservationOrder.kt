package com.fieldstudy.field_tms

import java.util.UUID

/** Serial snapshot order within this native owner's lifetime, never wall time. */
internal class ObservationOrder(
    private val newEpoch: () -> String = { UUID.randomUUID().toString() },
    initialSequence: Long = 0L,
) {
    private var epoch = newEpoch()
    private var sequence = initialSequence

    init { require(initialSequence in 0L..MAX_SEQUENCE) }

    fun next(): Stamp {
        // No wrap inside an epoch. A live Dart tracker treats this practically
        // unreachable owner rotation as a reconnect requirement.
        if (sequence == MAX_SEQUENCE) {
            epoch = newEpoch()
            sequence = 0L
        }
        sequence += 1L
        return Stamp(epoch, sequence)
    }

    data class Stamp(val epoch: String, val sequence: Long)

    companion object {
        const val MAX_SEQUENCE = 9_007_199_254_740_991L
    }
}
