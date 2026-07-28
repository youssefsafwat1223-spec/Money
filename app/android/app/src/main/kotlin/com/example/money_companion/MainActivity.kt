package com.youssefsafwat.mali

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterFragmentActivity() {
    private data class SharedMessage(
        val id: String,
        val text: String,
        val sender: String?,
    )

    companion object {
        private val pendingSharedMessages = mutableListOf<SharedMessage>()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
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

                // Per-item lease (MALI-012): peek returns the queue without
                // clearing it; Dart acknowledges each message by id after its
                // import commits, so a crash mid-import re-delivers only the
                // unacknowledged remainder.
                "peekPendingSharedMessages" -> {
                    result.success(peekSharedMessagesJson())
                }

                "acknowledgeSharedMessage" -> {
                    val payloadId = call.argument<String>("payloadId")
                    result.success(
                        payloadId != null &&
                            pendingSharedMessages.removeAll { it.id == payloadId },
                    )
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
        pendingSharedMessages.add(
            SharedMessage(
                id = java.util.UUID.randomUUID().toString(),
                text = text,
                sender = sender?.takeIf { it.isNotEmpty() },
            ),
        )
        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.removeExtra(Intent.EXTRA_SUBJECT)
    }

    private fun drainSharedMessagesJson(): String? {
        if (pendingSharedMessages.isEmpty()) {
            return null
        }
        val messages = pendingSharedMessages.toList()
        pendingSharedMessages.clear()
        return toJson(messages)
    }

    private fun peekSharedMessagesJson(): String? {
        if (pendingSharedMessages.isEmpty()) {
            return null
        }
        return toJson(pendingSharedMessages.toList())
    }

    private fun toJson(messages: List<SharedMessage>): String {
        val array = JSONArray()
        messages.forEach { message ->
            val item = JSONObject()
            item.put("id", message.id)
            item.put("text", message.text)
            if (message.sender != null) {
                item.put("sender", message.sender)
            }
            array.put(item)
        }
        return array.toString()
    }
}
