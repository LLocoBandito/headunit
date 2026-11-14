package com.example.driver_baru

import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import java.io.File
import java.util.Date

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        val old = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                File(getExternalFilesDir(null), "crash_log.txt")
                    .appendText("=== ${Date()} [${t.name}]\n${Log.getStackTraceString(e)}\n")
            } catch (_: Throwable) {}
            old?.uncaughtException(t, e)
        }
        super.onCreate(savedInstanceState)
    }
}