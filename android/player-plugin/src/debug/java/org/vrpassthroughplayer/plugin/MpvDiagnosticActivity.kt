package org.vrpassthroughplayer.plugin

import org.godotengine.godot.GodotActivity
import org.godotengine.godot.xr.XRMode

/** Debug-only two-dimensional entry point. Same Godot/plugin/GPU/RVM player,
 * with OpenXR explicitly disabled. It proves no XR projection or passthrough.
 */
class MpvDiagnosticActivity : GodotActivity() {
    override fun getCommandLine(): MutableList<String> {
        val args = super.getCommandLine().filterNot { it == XRMode.OPENXR.cmdLineArg }.toMutableList()
        args.addAll(listOf(XRMode.REGULAR.cmdLineArg, "--xr-mode", "off", "--", "--mpv-diagnostic-2d"))
        return args
    }
}
