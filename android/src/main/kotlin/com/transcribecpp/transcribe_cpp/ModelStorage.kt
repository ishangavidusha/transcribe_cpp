package com.transcribecpp.transcribe_cpp

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * Where downloaded models live, and how much room is left for them.
 *
 * The no-backup directory, not files/ or cache/. Auto Backup copies files/ to
 * the user's Google Drive, which has a 25 MB per-app quota a single model would
 * blow through — and backing up a file that can be downloaded again is waste
 * either way. cache/ is cleared by the system when storage runs low, so a
 * 300 MB model would silently vanish between launches and be downloaded again.
 */
internal class ModelStorage(private val context: Context) : MethodChannel.MethodCallHandler {

    private fun directory(): File {
        val dir = File(context.noBackupFilesDir, "transcribe_cpp/models")
        if (!dir.isDirectory && !dir.mkdirs()) {
            throw IOException("Could not create ${dir.path}")
        }
        return dir
    }

    /**
     * Bytes a download can actually write.
     *
     * Usable space, not StorageManager.getAllocatableBytes. The allocatable
     * figure counts cache the system would clear, but only clears it for a
     * caller that reserves the space through StorageManager.allocateBytes, and
     * the download is written from Dart. Reporting space that a plain write
     * cannot reach would let a download start and fail near the end.
     */
    private fun freeBytes(): Long = directory().usableSpace

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "modelDirectory" -> result.success(directory().path)
                "freeBytes" -> result.success(freeBytes())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("storage_failed", e.message, null)
        }
    }
}
