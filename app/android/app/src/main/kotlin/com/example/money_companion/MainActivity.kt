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
import org.json.JSONObject

class MainActivity : FlutterFragmentActivity() {
    // MALI-013: shared/received messages are persisted in DurableCaptureQueue
    // (survives process death) — no process-memory-only list any more.

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
                // MALI-013: honest capability reporting. hasSmsPermission used
                // to return the NOTIFICATION permission — a lie. Notification
                // permission is reported separately and never as SMS.
                "captureCapabilities" -> {
                    val caps = JSONObject()
                    caps.put("supportsShareCapture", CaptureSettings.supportsShareCapture())
                    caps.put("receiveSmsDeclared", CaptureSettings.receiveSmsDeclared(this))
                    caps.put("hasReceiveSmsPermission", CaptureSettings.hasReceiveSmsPermission(this))
                    caps.put("canUseAutomaticSmsCapture", CaptureSettings.canUseAutomaticSmsCapture(this))
                    caps.put("isAutomaticSmsCaptureEnabled", CaptureSettings.isAutoCaptureEnabled(this))
                    caps.put("hasNotificationPermission", hasNotificationPermission())
                    result.success(caps.toString())
                }

                "setAutomaticSmsCaptureEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    CaptureSettings.setAutoCaptureEnabled(this, enabled)
                    result.success(CaptureSettings.isAutoCaptureEnabled(this))
                }

                "openAppSettings" -> {
                    openAppSettings()
                    result.success(null)
                }

                // Legacy destructive drain — kept for the Dart compat method
                // consumePendingSharedMessages(); prefer peek + ack.
                "consumePendingSharedMessages" -> {
                    result.success(DurableCaptureQueue.get(this).drainJson())
                }

                // Per-item lease (MALI-012 + MALI-013): peek returns the durable
                // queue without clearing it; Dart acknowledges each message by id
                // after its import commits, so a crash/process death mid-import
                // re-delivers only the unacknowledged remainder.
                "peekPendingSharedMessages" -> {
                    result.success(DurableCaptureQueue.get(this).peekJson())
                }

                "acknowledgeSharedMessage" -> {
                    val payloadId = call.argument<String>("payloadId")
                    result.success(
                        payloadId != null &&
                            DurableCaptureQueue.get(this).acknowledge(payloadId),
                    )
                }

                else -> result.notImplemented()
            }
        }
    }

    // Honest: this is the NOTIFICATION permission, never reported as SMS.
    private fun hasNotificationPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
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
        // Durable enqueue — survives process death until Flutter acks the import.
        DurableCaptureQueue.get(this).enqueue(
            DurableCaptureQueue.Item(
                id = java.util.UUID.randomUUID().toString(),
                text = text,
                sender = sender?.takeIf { it.isNotEmpty() },
                source = "share",
                receivedAt = DurableCaptureQueue.isoNow(),
            ),
        )
        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.removeExtra(Intent.EXTRA_SUBJECT)
    }
}
