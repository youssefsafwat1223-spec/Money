package com.youssefsafwat.mali

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private val pendingSharedMessages = mutableListOf<Pair<String, String?>>()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureSharedText(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureSharedText(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "money_companion/native_capture",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasSmsPermission" -> {
                    result.success(hasSmsPermission())
                }

                "openAppSettings" -> {
                    openAppSettings()
                    result.success(null)
                }

                "consumePendingSharedMessages" -> {
                    result.success(drainSharedMessagesJson())
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun hasSmsPermission(): Boolean {
        val notificationsGranted =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED

        return notificationsGranted
    }

    private fun openAppSettings() {
        val intent =
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        startActivity(intent)
    }

    private fun captureSharedText(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND || intent.type != "text/plain") {
            return
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        if (text.isNullOrEmpty()) {
            return
        }
        val sender = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim()
        pendingSharedMessages.add(text to sender?.takeIf { it.isNotEmpty() })
        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.removeExtra(Intent.EXTRA_SUBJECT)
    }

    private fun drainSharedMessagesJson(): String? {
        if (pendingSharedMessages.isEmpty()) {
            return null
        }
        val messages = pendingSharedMessages.toList()
        pendingSharedMessages.clear()
        val array = JSONArray()
        messages.forEach { (text, sender) ->
            val item = JSONObject()
            item.put("text", text)
            if (sender != null) {
                item.put("sender", sender)
            }
            array.put(item)
        }
        return array.toString()
    }
}
