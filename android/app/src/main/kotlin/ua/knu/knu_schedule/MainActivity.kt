package ua.knu.knu_schedule

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "ua.knu.knu_schedule/save_pdf"
        private const val REQUEST_CODE_SAVE_PDF = 1001
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            if (call.method != "savePdf") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            if (pendingResult != null) {
                result.error("BUSY", "Збереження вже виконується", null)
                return@setMethodCallHandler
            }

            val fileName = call.argument<String>("fileName")
            val bytes = call.argument<ByteArray>("bytes")

            if (fileName.isNullOrBlank() || bytes == null) {
                result.error("INVALID_ARGUMENTS", "Не передано ім'я або дані PDF", null)
                return@setMethodCallHandler
            }

            pendingResult = result
            pendingBytes = bytes

            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/pdf"
                putExtra(Intent.EXTRA_TITLE, fileName)
            }

            try {
                startActivityForResult(intent, REQUEST_CODE_SAVE_PDF)
            } catch (e: Exception) {
                pendingResult = null
                pendingBytes = null
                result.error("SAVE_DIALOG_ERROR", e.message, null)
            }
        }
    }

    @Deprecated("Using Activity Result API would require additional migration")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != REQUEST_CODE_SAVE_PDF) return

        val result = pendingResult
        val bytes = pendingBytes

        pendingResult = null
        pendingBytes = null

        if (result == null) return

        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }

        val uri: Uri? = data?.data

        if (uri == null || bytes == null) {
            result.error("SAVE_FAILED", "Android не повернув файл для збереження", null)
            return
        }

        try {
            val output = contentResolver.openOutputStream(uri, "w")
                ?: throw IOException("Не вдалося відкрити вибраний файл")

            output.use {
                it.write(bytes)
            }

            result.success(uri.toString())
        } catch (e: Exception) {
            result.error("SAVE_FAILED", e.message, null)
        }
    }
}
