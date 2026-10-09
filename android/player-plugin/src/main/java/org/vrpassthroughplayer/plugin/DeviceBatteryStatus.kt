package org.vrpassthroughplayer.plugin

import android.os.BatteryManager

/** Interpret one sticky battery snapshot; a power cable alone does not imply charging. */
internal object DeviceBatteryStatus {
    data class State(val level: Int, val charging: Boolean, val plugged: Boolean)

    fun resolve(level: Int, scale: Int, status: Int, plug: Int,
                capacityFallback: Int, chargingFallback: Boolean): State {
        val percent = if (scale > 0 && level in 0..scale) (level.toLong() * 100 / scale).toInt()
            else capacityFallback.takeIf { it in 0..100 } ?: -1
        val charging = when (status) {
            BatteryManager.BATTERY_STATUS_CHARGING -> true
            BatteryManager.BATTERY_STATUS_FULL -> plug != 0
            BatteryManager.BATTERY_STATUS_DISCHARGING, BatteryManager.BATTERY_STATUS_NOT_CHARGING -> false
            else -> chargingFallback
        }
        return State(percent, charging, if (plug >= 0) plug != 0 else charging)
    }
}
