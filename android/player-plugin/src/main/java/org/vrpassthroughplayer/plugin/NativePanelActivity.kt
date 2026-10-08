package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import java.util.UUID

/** Native text/WebView panels are displayed in PICO's 2D VR shell. */
open class NativePanelActivity : Activity() {
    private var permit: String? = null
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        permit = gate.enter(javaClass.name, state?.getString(STATE))
        if (permit == null) { finish(); return }
        Log.i("PlayerNativePanel", "opened ${javaClass.simpleName}")
    }
    override fun onSaveInstanceState(out: Bundle) {
        permit?.let { out.putString(STATE, it) }
        super.onSaveInstanceState(out)
    }
    override fun onDestroy() {
        if (!isChangingConfigurations) permit?.let { gate.leave(javaClass.name, it) }
        super.onDestroy()
    }
    companion object {
        private const val STATE = "player_panel_permit"
        private val gate = PanelLaunchGate(SystemClock::elapsedRealtime)

        fun open(host: Activity, target: Class<out NativePanelActivity>) {
            val token = UUID.randomUUID().toString()
            gate.arm(target.name, token)
            try {
                val meta = host.packageManager.getApplicationInfo(host.packageName, PackageManager.GET_META_DATA).metaData
                val pico = meta?.getString("pvr.app.type") == "vr"
                val intent = if (pico) {
                    // PICO's official AndroidHelper.startVRShell(way=0, args).
                    // https://github.com/picoxr/AndroidHelper/blob/master/app/src/main/java/com/picovr/androidhelper/DeviceHelper.java
                    Intent("pvr.intent.action.VRSHELL").apply {
                        putExtra("way", 0)
                        putExtra("args", arrayOf(host.packageName, target.name))
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                        val shell = resolveActivity(host.packageManager)
                            ?: throw IllegalStateException("PICO 2D shell unavailable")
                        component = shell
                    }
                } else Intent(host, target)
                host.startActivity(intent)
                Log.i("PlayerNativePanel", "requested ${target.simpleName} shell=$pico")
                Handler(Looper.getMainLooper()).postDelayed({
                    if (gate.cancelPending(target.name, token) && !host.isDestroyed && !host.isFinishing) {
                        Log.e("PlayerNativePanel", "Timed out opening ${target.simpleName}")
                        runCatching { host.startActivity(Intent(host, host.javaClass)
                            .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)) }
                        Toast.makeText(host, UiLanguage.tr(host, "Unable to open account settings.", "无法打开账号设置。"), Toast.LENGTH_LONG).show()
                    }
                }, 15_000)
            } catch (error: Exception) {
                gate.cancel(target.name)
                Log.e("PlayerNativePanel", "Unable to open ${target.simpleName}", error)
                Toast.makeText(host, UiLanguage.tr(host, "Unable to open account settings.", "无法打开账号设置。"), Toast.LENGTH_LONG).show()
            }
        }
    }
}
