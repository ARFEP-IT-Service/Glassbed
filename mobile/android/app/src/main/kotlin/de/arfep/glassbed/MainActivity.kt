package de.arfep.glassbed

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Hosts the Flutter UI and implements the platform channel "de.arfep.glassbed/platform":
 * multicast lock for mDNS, the Android 17 local network permission, saving and opening files
 * through the system file picker (Storage Access Framework, so no storage permission is needed),
 * rendering PDF pages with the platform's PdfRenderer and files shared to Glassbed by other apps.
 * Update installs are delegated to UpdateInstaller (src/github; the play twin does nothing).
 */
class MainActivity : FlutterActivity() {

    private class PendingFile(val name: String, val mimeType: String, val bytes: ByteArray)

    private var multicastLock: WifiManager.MulticastLock? = null
    private var permissionResult: MethodChannel.Result? = null
    private var saveResult: MethodChannel.Result? = null
    private var pendingFiles: List<PendingFile> = emptyList()
    private var pickResult: MethodChannel.Result? = null
    private var sharedUris: List<Uri> = emptyList()
    private var channel: MethodChannel? = null
    private val io = Executors.newSingleThreadExecutor()
    // PdfRenderer is not thread-safe: all rendering runs on this one background thread.
    private val pdf = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val updates by lazy { UpdateInstaller(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated activity or a launch from "recents" carries the old share intent again.
        val fromHistory = intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (savedInstanceState == null && !fromHistory) takeShare(intent)
        // A fresh start: downloads of an earlier run are no longer needed.
        if (savedInstanceState == null) io.execute { updates.cleanup() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (takeShare(intent)) channel?.invokeMethod("sharedFilesAvailable", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .also { it.setMethodCallHandler(::onMethodCall) }
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
            "pickDocuments" -> pickDocuments(result)
            "takeSharedFiles" -> takeSharedFiles(result)
            "pdfPageCount" -> pdfPageCount(call, result)
            "renderPdfPage" -> renderPdfPage(call, result)
            // first entry = the ABI the device prefers (picks the matching APK of a release)
            "deviceAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull())
            "updatesDir" -> result.success(updates.dir()?.path)
            "installUpdate" -> try {
                result.success(updates.install(call.argument<String>("path")))
            } catch (e: Exception) {
                result.error("install_failed", e.message, null)
            }
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
        if (requestCode == REQUEST_PICK) {
            onPicked(resultCode, data)
            return
        }
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

    // --- Opening files: document picker and "share to Glassbed" ---

    private fun pickDocuments(result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("busy", "The file picker is already open.", null)
            return
        }
        pickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, OPEN_TYPES)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_PICK)
        } catch (e: Exception) {
            pickResult = null
            result.error("pick_failed", e.message, null)
        }
    }

    private fun onPicked(resultCode: Int, data: Intent?) {
        val result = pickResult ?: return
        pickResult = null
        val uris = mutableListOf<Uri>()
        if (resultCode == Activity.RESULT_OK && data != null) {
            val clip = data.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add)
            } else {
                data.data?.let(uris::add)
            }
        }
        readFiles(uris, result)
    }

    /** Remembers the content:// URIs of a share intent; true if there were any. */
    private fun takeShare(intent: Intent?): Boolean {
        if (intent == null) return false
        val uris = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> intent.streamUri()?.let(uris::add)
            Intent.ACTION_SEND_MULTIPLE -> uris.addAll(intent.streamUris())
            else -> return false
        }
        // Consumed: a later recreation must not add the same files again.
        intent.action = Intent.ACTION_MAIN
        if (uris.isEmpty()) return false
        sharedUris = sharedUris + uris
        return true
    }

    private fun takeSharedFiles(result: MethodChannel.Result) {
        val uris = sharedUris
        sharedUris = emptyList()
        readFiles(uris, result)
    }

    /**
     * Reads the files in the background (the temporary read grant of the picker or the share
     * is enough, no permission). Files that cannot be read are returned without "bytes".
     */
    private fun readFiles(uris: List<Uri>, result: MethodChannel.Result) {
        if (uris.isEmpty()) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        io.execute {
            val files = uris.map { uri ->
                val name = displayName(uri)
                val mime = contentResolver.getType(uri) ?: mimeFromName(name)
                val bytes = try {
                    readLimited(uri)
                } catch (e: Exception) {
                    null
                }
                mapOf("name" to name, "mimeType" to mime, "bytes" to bytes)
            }
            main.post { result.success(files) }
        }
    }

    private fun readLimited(uri: Uri): ByteArray {
        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("Could not open $uri")
        return input.use { stream ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = stream.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > MAX_FILE_BYTES) throw IllegalStateException("File too large")
            }
            out.toByteArray()
        }
    }

    private fun displayName(uri: Uri): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c ->
                    if (c.moveToFirst()) {
                        val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (i >= 0) c.getString(i)?.let { if (it.isNotBlank()) return it }
                    }
                }
        } catch (_: Exception) {
            // Some providers do not support the query; fall back to the URI.
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "file"
    }

    private fun mimeFromName(name: String): String =
        when (name.substringAfterLast('.', "").lowercase()) {
            "pdf" -> "application/pdf"
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            else -> "application/octet-stream"
        }

    @Suppress("DEPRECATION")
    private fun Intent.streamUri(): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun Intent.streamUris(): List<Uri> =
        (
            if (Build.VERSION.SDK_INT >= 33) {
                getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
        ).orEmpty().filterNotNull()

    // --- PDF pages with the platform renderer (android.graphics.pdf.PdfRenderer) ---

    /** Temporary copies of open PDFs, keyed by a hash of their content (PdfRenderer needs a file). */
    private val pdfFiles = LinkedHashMap<String, File>()

    private fun pdfFile(bytes: ByteArray): File {
        val key = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        val cached = pdfFiles.remove(key)
        if (cached != null && cached.exists()) {
            pdfFiles[key] = cached // most recently used last
            return cached
        }
        val dir = File(cacheDir, "pdf").apply { mkdirs() }
        val file = File(dir, "$key.pdf")
        file.writeBytes(bytes)
        pdfFiles[key] = file
        while (pdfFiles.size > MAX_PDF_FILES) {
            val oldest = pdfFiles.keys.first()
            pdfFiles.remove(oldest)?.delete()
        }
        return file
    }

    private fun <T> withRenderer(bytes: ByteArray, block: (PdfRenderer) -> T): T {
        val fd = ParcelFileDescriptor.open(pdfFile(bytes), ParcelFileDescriptor.MODE_READ_ONLY)
        // PdfRenderer closes the descriptor itself.
        return PdfRenderer(fd).use(block)
    }

    private fun pdfPageCount(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
            ?: return result.error("bad_args", "bytes missing", null)
        pdf.execute {
            try {
                val count = withRenderer(bytes) { it.pageCount }
                main.post { result.success(count) }
            } catch (e: Exception) {
                main.post { result.error("pdf_failed", e.message, null) }
            }
        }
    }

    /**
     * Renders one page at "dpi" on white. Returns RGBA pixels (row by row, 4 bytes per pixel)
     * plus the page size in points (1/72 inch).
     */
    private fun renderPdfPage(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
            ?: return result.error("bad_args", "bytes missing", null)
        val index = call.argument<Int>("index") ?: 0
        val dpi = (call.argument<Int>("dpi") ?: 72).coerceIn(10, 600)
        pdf.execute {
            try {
                val page = withRenderer(bytes) { renderer ->
                    renderer.openPage(index).use { p -> renderPage(p, dpi) }
                }
                main.post { result.success(page) }
            } catch (e: Exception) {
                main.post { result.error("pdf_failed", e.message, null) }
            }
        }
    }

    private fun renderPage(p: PdfRenderer.Page, dpi: Int): Map<String, Any> {
        val widthPt = p.width
        val heightPt = p.height
        var scale = dpi / 72.0
        // Guard against absurd page sizes: at most about 40 megapixels.
        val pixels = widthPt * scale * heightPt * scale
        if (pixels > MAX_PIXELS) scale *= sqrt(MAX_PIXELS / pixels)
        val w = (widthPt * scale).roundToInt().coerceAtLeast(1)
        val h = (heightPt * scale).roundToInt().coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(Color.WHITE) // transparent PDF backgrounds print as white paper
            val matrix = Matrix().apply { setScale(w / widthPt.toFloat(), h / heightPt.toFloat()) }
            val mode = if (dpi >= 150) {
                PdfRenderer.Page.RENDER_MODE_FOR_PRINT
            } else {
                PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY
            }
            p.render(bitmap, null, matrix, mode)
            // ARGB_8888 is stored as R, G, B, A bytes in memory.
            val buffer = ByteBuffer.allocate(bitmap.byteCount)
            bitmap.copyPixelsToBuffer(buffer)
            return mapOf(
                "width" to w,
                "height" to h,
                "rgba" to buffer.array(),
                "widthPt" to widthPt.toDouble(),
                "heightPt" to heightPt.toDouble(),
            )
        } finally {
            bitmap.recycle()
        }
    }

    override fun onDestroy() {
        releaseMulticastLock()
        io.shutdown()
        pdf.shutdown()
        if (isFinishing) File(cacheDir, "pdf").deleteRecursively()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "de.arfep.glassbed/platform"
        private const val PERMISSION_LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
        private const val API_LOCAL_NETWORK = 37
        private const val REQUEST_LOCAL_NETWORK = 4701
        private const val REQUEST_SAVE = 4702
        private const val REQUEST_PICK = 4703
        private val OPEN_TYPES = arrayOf("application/pdf", "image/jpeg", "image/png")
        private const val MAX_FILE_BYTES = 200 * 1024 * 1024
        private const val MAX_PDF_FILES = 4
        private const val MAX_PIXELS = 40_000_000.0
    }
}
