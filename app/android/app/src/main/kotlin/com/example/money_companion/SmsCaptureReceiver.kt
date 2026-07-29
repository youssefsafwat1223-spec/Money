package com.youssefsafwat.mali

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import java.util.UUID

/**
 * MALI-013 — optional automatic bank-SMS capture (opt-in).
 *
 * Declared behind a build-level manifest placeholder so a Play-safe, share-only
 * build can omit RECEIVE_SMS entirely (see AndroidManifest.xml). Even when the
 * permission is granted, capture stays OFF until the user explicitly enables it
 * (CaptureSettings.autoCaptureEnabled) — permission alone never starts reading.
 *
 * Received messages are pre-filtered locally to plausible financial/bank
 * messages and routed through the SAME DurableCaptureQueue as share capture, so
 * everything downstream (parser, dedup, atomic local import, peek/ack) is
 * identical. Unrelated SMS are dropped here and never stored or uploaded. Raw
 * bodies are never logged.
 */
class SmsCaptureReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        // Gate: user opt-in required; a granted permission is not consent to read.
        if (!CaptureSettings.isAutoCaptureEnabled(context)) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        // Multipart SMS arrive as several parts of one logical message.
        val body = StringBuilder()
        var sender: String? = null
        for (part in messages) {
            body.append(part.messageBody ?: "")
            if (sender == null) sender = part.originatingAddress
        }
        val text = body.toString().trim()
        if (text.isEmpty() || !looksFinancial(text)) return // drop unrelated SMS

        DurableCaptureQueue.get(context).enqueue(
            DurableCaptureQueue.Item(
                id = UUID.randomUUID().toString(),
                text = text,
                sender = sender?.trim()?.takeIf { it.isNotEmpty() },
                source = "sms",
                receivedAt = DurableCaptureQueue.isoNow(),
            ),
        )
    }

    /**
     * Conservative local pre-filter so only plausibly-financial messages are
     * stored. The authoritative parse still runs in the Dart engine; this only
     * prevents unrelated SMS from ever entering the queue. Intentionally broad
     * (amount-like token OR a bank/transaction keyword) to avoid dropping real
     * bank messages, while excluding chit-chat/OTP-only texts.
     */
    private fun looksFinancial(text: String): Boolean {
        val lower = text.lowercase()
        val hasAmount = Regex("""\d[\d,]*\.?\d*\s?(sar|aed|egp|usd|eur|gbp|ر\.س|ريال|درهم|جنيه|\$|€|£)""")
            .containsMatchIn(lower)
        val keywords = listOf(
            "purchase", "payment", "transaction", "withdraw", "deposit", "transfer",
            "debited", "credited", "balance", "pos", "card",
            "شراء", "دفع", "عملية", "سحب", "إيداع", "تحويل", "خصم", "رصيد", "بطاقة",
        )
        val hasKeyword = keywords.any { lower.contains(it) }
        return hasAmount || hasKeyword
    }
}
