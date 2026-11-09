package de.arfep.glassbed

import android.app.Activity
import java.io.File

/**
 * play build: no in-app updates (the store updates the app). Same API as the github twin so
 * MainActivity compiles for both flavors; it never downloads or installs anything.
 */
@Suppress("UNUSED_PARAMETER")
class UpdateInstaller(activity: Activity) {

    fun dir(): File? = null

    fun cleanup() {}

    fun install(path: String?): String = "unsupported"
}
