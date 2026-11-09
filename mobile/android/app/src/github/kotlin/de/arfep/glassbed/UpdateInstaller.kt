package de.arfep.glassbed

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

/** FileProvider of its own, so it cannot clash with one declared by a library. */
class UpdateFileProvider : FileProvider()

/**
 * github build: hands a downloaded, already verified APK to Android's package installer.
 * Android shows its own "Install" confirmation; nothing is installed silently and the app
 * does not restart itself. The play build has a twin of this class that installs nothing.
 */
class UpdateInstaller(private val activity: Activity) {

    /** cache/updates – the only folder the FileProvider exposes (res/xml/update_paths.xml). */
    fun dir(): File = File(activity.cacheDir, DIR).apply { mkdirs() }

    /** Removes downloads of an earlier run (installed, cancelled or abandoned). */
    fun cleanup() {
        File(activity.cacheDir, DIR).listFiles()?.forEach { it.deleteRecursively() }
    }

    /** Whether Glassbed may install apps (the user allowed it in Android's settings). */
    fun canInstall(): Boolean = activity.packageManager.canRequestPackageInstalls()

    /**
     * "started": the installer is open; "needs_permission": Glassbed may not install apps yet
     * and Android's settings page for that was opened; "invalid": not an APK in [dir].
     */
    fun install(path: String?): String {
        val file = path?.let { File(it).canonicalFile } ?: return "invalid"
        if (file.parentFile != dir().canonicalFile || !file.name.endsWith(".apk") || !file.isFile) {
            return "invalid"
        }
        if (!activity.packageManager.canRequestPackageInstalls()) {
            val settings = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${activity.packageName}"),
            )
            activity.startActivity(settings)
            return "needs_permission"
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_TYPE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(intent)
        return "started"
    }

    companion object {
        private const val DIR = "updates"
        private const val APK_TYPE = "application/vnd.android.package-archive"
    }
}
