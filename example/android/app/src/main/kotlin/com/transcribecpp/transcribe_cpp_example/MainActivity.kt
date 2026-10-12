package com.transcribecpp.transcribe_cpp_example

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "transcribe_cpp_example/background",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    askToNotify()
                    ListeningService.start(this)
                    result.success(null)
                }
                "stop" -> {
                    ListeningService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // From Android 13 the service's notification needs permission to show.
    // The service runs either way; without it the user just cannot see why
    // the microphone indicator is on.
    private fun askToNotify() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
    }
}
