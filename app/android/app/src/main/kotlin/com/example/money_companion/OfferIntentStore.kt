package com.example.money_companion

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * COUPONS Phase 5 — shared merchant links, staged for the app.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * DELIBERATELY SEPARATE FROM DurableCaptureQueue.
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * A shared shop link and a shared bank message are different kinds of thing and
 * must not share a store. Putting a URL in the capture queue would mean:
 *
 *   * the SMS parser reading a product page as a transaction — URLs are full of
 *     digits and currency words, which is exactly the shape it looks for;
 *   * a shopping URL persisted in the store built for bank messages, which is
 *     encrypted for that purpose and drains under financial consent;
 *   * a user who shared a link and got a transaction.
 *
 * Two stores make that impossible rather than merely unlikely.
 *
 * ## What is stored
 *
 * A SANITIZED url — scheme, host and path only. The query and fragment are
 * destroyed before anything is written, because a shared shopping URL routinely
 * carries a session id, a cart id, the sharer's own referral code and analytics
 * parameters that identify them. None of that is needed to know which merchant
 * this is; the host alone answers that.
 *
 * ## Why not encrypted
 *
 * The capture queue holds bank messages. This holds "somebody shared a link to
 * shop.example". It is bounded, short-lived, and drained on the next app launch.
 * Encrypting it would imply it holds something it deliberately does not.
 */
object OfferIntentStore {
    private const val PREFS = "qirsh_offer_intents"
    private const val KEY = "pending"

    /**
     * Small on purpose. This is a hand-off buffer, not a queue: a user shares a
     * link and opens the app. If dozens accumulate, something is wrong and the
     * right response is to drop the oldest rather than grow without bound.
     */
    private const val MAX_ITEMS = 20

    data class Item(
        val id: String,
        val url: String,
        val host: String,
        val receivedAt: String,
    )

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isoNow(): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date())
    }

    @Synchronized
    fun enqueue(context: Context, item: Item) {
        // Refuse anything that is not already sanitized. The caller sanitizes;
        // this is the second lock, because a raw URL reaching disk is the one
        // outcome this store exists to prevent.
        if (item.url.contains('?') || item.url.contains('#')) return
        if (!item.url.startsWith("https://")) return

        val items = load(context).toMutableList()
        // Same host and path twice in a row is a double-share, not two intents.
        if (items.any { it.url == item.url }) return
        items.add(item)
        while (items.size > MAX_ITEMS) items.removeAt(0)
        save(context, items)
    }

    @Synchronized
    fun drain(context: Context): List<Item> {
        val items = load(context)
        // Cleared on read. Unlike a capture, an offer intent has no durability
        // requirement: the worst case for losing one is the user taps the link
        // again, whereas a lost bank message is a missing transaction.
        prefs(context).edit().remove(KEY).apply()
        return items
    }

    @Synchronized
    fun peek(context: Context): List<Item> = load(context)

    private fun load(context: Context): List<Item> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { i ->
                val o = array.optJSONObject(i) ?: return@mapNotNull null
                val url = o.optString("url")
                val host = o.optString("host")
                if (url.isEmpty() || host.isEmpty()) return@mapNotNull null
                Item(
                    id = o.optString("id"),
                    url = url,
                    host = host,
                    receivedAt = o.optString("receivedAt"),
                )
            }
        } catch (_: Exception) {
            // Corrupt store: drop it. There is nothing here worth recovering,
            // and a parse loop that throws on every launch would be worse.
            emptyList()
        }
    }

    private fun save(context: Context, items: List<Item>) {
        val array = JSONArray()
        for (item in items) {
            array.put(
                JSONObject()
                    .put("id", item.id)
                    .put("url", item.url)
                    .put("host", item.host)
                    .put("receivedAt", item.receivedAt),
            )
        }
        prefs(context).edit().putString(KEY, array.toString()).apply()
    }
}
