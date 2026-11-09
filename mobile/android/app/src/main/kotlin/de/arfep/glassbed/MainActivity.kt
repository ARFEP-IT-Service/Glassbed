package de.arfep.glassbed

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Hosts the Flutter UI and implements the platform channel "de.arfep.glassbed/platform":
 * multicast lock for mDNS, the Android 17 local network permission and saving files through
 * the system file picker (Storage Access Framework, so no storage permission is needed).
 */
class MainActivity : FlutterActivity() {

    private class PendingFile(val name: String, val mimeType: String, val bytes: ByteArray)

    private var multicastLock: WifiManager.MulticastLock? = null
    private var permissionResult: MethodChannel.Result? = null
    private var saveResult: MethodChannel.Result? = null
    private var pendingFiles: List<PendingFile> = emptyList()
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquireMulticastLock" -> {
                acquireMulticastLock()
                result.success(null)
            }
            "releaseMulticastLock" -> {
                releaseMulticastLock()
                result.success(null)
            }
            "localNetworkAllowed" -> result.success(localNetworkAllowed())
            "requestLocalNetwork" -> requestLocalNetwork(result)
            "saveFiles" -> saveFiles(call, result)
            else -> result.notImplemented()
        }
    }

    // --- Multicast lock (mDNS answers are multicast; Wi-Fi drivers drop them without it) ---

    private fun acquireMulticastLock() {
        val lock = multicastLock ?: run {
            val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            wifi.createMulticastLock("glassbed-mdns").apply { setReferenceCounted(false) }
                .also { multicastLock = it }
        }
        if (!lock.isHeld) lock.acquire()
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { if (it.isHeld) it.release() }
    }

    // --- Local network permission (runtime permission only from Android 17, API 37) ---

    private fun localNetworkAllowed(): Boolean {
        if (Build.VERSION.SDK_INT < API_LOCAL_NETWORK) return true
        return checkSelfPermission(PERMISSION_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestLocalNetwork(result: MethodChannel.Result) {
        if (localNetworkAllowed()) {
            result.success(true)
            return
        }
        if (permissionResult != null) {
            result.error("busy", "A permission request is already running.", null)
            return
        }
        permissionResult = result
        requestPermissions(arrayOf(PERMISSION_LOCAL_NETWORK), REQUEST_LOCAL_NETWORK)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_LOCAL_NETWORK) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionResult?.success(granted)
        permissionResult = null
    }

    // --- Saving through the system file picker ---

    private fun saveFiles(call: MethodCall, result: MethodChannel.Result) {
        if (saveResult != null) {
            result.error("busy", "Saving is already in progress.", null)
            return
        }
        val raw = call.argument<List<Map<String, Any?>>>("files").orEmpty()
        val files = raw.mapNotNull { m ->
            val name = m["name"] as? String ?: return@mapNotNull null
            val mime = m["mimeType"] as? String ?: "application/octet-stream"
            val bytes = m["bytes"] as? ByteArray ?: return@mapNotNull null
            PendingFile(name, mime, bytes)
        }
        if (files.isEmpty()) {
            result.success(0)
            return
        }
        saveResult = result
        pendingFiles = files
        val intent = if (files.size == 1) {
            Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = files[0].mimeType
                putExtra(Intent.EXTRA_TITLE, files[0].name)
            }
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_SAVE)
        } catch (e: Exception) {
            finishSave(error = e)
        }
    }

    @Deprecated("Activity result API of the framework Activity used by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_SAVE) return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            finishSave(count = 0)
            return
        }
        val files = pendingFiles
        // Writing several megabytes must not block the UI thread.
        io.execute {
            try {
                val count = if (files.size == 1) {
                    write(uri, files[0].bytes)
                    1
                } else {
                    writeIntoTree(uri, files)
                }
                main.post { finishSave(count = count) }
            } catch (e: Exception) {
                main.post { finishSave(error = e) }
            }
        }
    }

    private fun writeIntoTree(treeUri: Uri, files: List<PendingFile>): Int {
        val dir = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        var count = 0
        for (f in files) {
            val doc = DocumentsContract.createDocument(contentResolver, dir, f.mimeType, f.name)
                ?: throw IllegalStateException("Could not create ${f.name}")
            write(doc, f.bytes)
            count++
        }
        return count
    }

    private fun write(uri: Uri, bytes: ByteArray) {
        // "wt" truncates when an existing file is overwritten via the picker.
        val out = contentResolver.openOutputStream(uri, "wt")
            ?: throw IllegalStateException("Could not open $uri")
        out.use { it.write(bytes) }
    }

    private fun finishSave(count: Int = 0, error: Exception? = null) {
        val result = saveResult
        saveResult = null
        pendingFiles = emptyList()
        if (error != null) {
            result?.error("save_failed", error.message, null)
        } else {
            result?.success(count)
        }
    }

    override fun onDestroy() {
        releaseMulticastLock()
        io.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "de.arfep.glassbed/platform"
        private const val PERMISSION_LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
        private const val API_LOCAL_NETWORK = 37
        private const val REQUEST_LOCAL_NETWORK = 4701
        private const val REQUEST_SAVE = 4702
    }
}
