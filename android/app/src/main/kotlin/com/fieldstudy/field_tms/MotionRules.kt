package com.fieldstudy.field_tms

internal object MotionRules {
    fun pausedStatus(current: String, sensorAvailable: Boolean, permissionGranted: Boolean): String = when {
        current in setOf("permissionDenied", "unavailable", "error") -> current
        !sensorAvailable -> "unavailable"
        !permissionGranted -> "permissionDenied"
        else -> "paused"
    }

    fun distance(status: String, sensorAvailable: Boolean, steps: Long, stepLengthM: Double?): Double? {
        if (!sensorAvailable || status in setOf("unavailable", "error", "permissionDenied")) return null
        return stepLengthM?.let { steps * it }
    }
}
