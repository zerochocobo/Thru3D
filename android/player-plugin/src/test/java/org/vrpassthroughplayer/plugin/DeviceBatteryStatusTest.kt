package org.vrpassthroughplayer.plugin

import android.os.BatteryManager
import org.junit.Assert.*
import org.junit.Test

class DeviceBatteryStatusTest {
    @Test fun stickyChargingStatusWinsOverManagerFalse() {
        for (plug in listOf(BatteryManager.BATTERY_PLUGGED_AC, BatteryManager.BATTERY_PLUGGED_USB, BatteryManager.BATTERY_PLUGGED_WIRELESS)) {
            assertEquals(DeviceBatteryStatus.State(75, true, true),
                DeviceBatteryStatus.resolve(150, 200, BatteryManager.BATTERY_STATUS_CHARGING, plug, 12, false))
        }
    }

    @Test fun cableWithInsufficientPowerIsNotReportedAsCharging() {
        for (status in listOf(BatteryManager.BATTERY_STATUS_DISCHARGING, BatteryManager.BATTERY_STATUS_NOT_CHARGING)) {
            assertEquals(DeviceBatteryStatus.State(12, false, true),
                DeviceBatteryStatus.resolve(12, 100, status, BatteryManager.BATTERY_PLUGGED_USB, 85, true))
        }
    }

    @Test fun fullBatteryShowsChargingOnlyWhilePowerIsConnected() {
        assertEquals(DeviceBatteryStatus.State(100, true, true),
            DeviceBatteryStatus.resolve(100, 100, BatteryManager.BATTERY_STATUS_FULL, 1, -1, false))
        assertEquals(DeviceBatteryStatus.State(100, false, false),
            DeviceBatteryStatus.resolve(100, 100, BatteryManager.BATTERY_STATUS_FULL, 0, -1, true))
    }

    @Test fun unpluggedSnapshotClearsStaleManagerChargingState() {
        assertEquals(DeviceBatteryStatus.State(85, false, false),
            DeviceBatteryStatus.resolve(85, 100, BatteryManager.BATTERY_STATUS_DISCHARGING, 0, 85, true))
    }

    @Test fun unavailableBroadcastUsesManagerWithoutInventingALevel() {
        assertEquals(DeviceBatteryStatus.State(42, true, true),
            DeviceBatteryStatus.resolve(-1, -1, BatteryManager.BATTERY_STATUS_UNKNOWN, -1, 42, true))
        for (capacity in listOf(-1, Int.MIN_VALUE, 101)) {
            assertEquals(DeviceBatteryStatus.State(-1, false, false),
                DeviceBatteryStatus.resolve(-1, -1, BatteryManager.BATTERY_STATUS_UNKNOWN, -1, capacity, false))
        }
    }

    @Test fun invalidBroadcastLevelFallsBackAndZeroIsAValidLevel() {
        for ((level, scale) in listOf(101 to 100, -1 to 100, 10 to 0)) {
            assertEquals(38, DeviceBatteryStatus.resolve(level, scale, BatteryManager.BATTERY_STATUS_UNKNOWN, 0, 38, false).level)
        }
        assertEquals(0, DeviceBatteryStatus.resolve(0, 100, BatteryManager.BATTERY_STATUS_CHARGING, 1, 38, false).level)
    }
}
