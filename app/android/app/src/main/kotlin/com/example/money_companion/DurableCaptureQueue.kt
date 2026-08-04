package com.youssefsafwat.mali

import android.content.Context
import android.content.SharedPreferences
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import org.json.JSONArray
import org.json.JSONObject

/**
 * MALI-013 — durable, retry-safe queue for captured bank messages on Android.
 *
 * Replaces the old process-memory-only list: captured messages (shared-to-Mali
 * or, when enabled, received SMS) are persisted to SharedPreferences so they
 * survive process death, app restart, and Flutter engine recreation. A message
 * is only removed once Flutter acknowledges a successful local import
 * (peek → import → ack), so a crash mid-import re-delivers only the
 * unacknowledged remainder.
 *
 * Contract: enqueue / peek / acknowledge, idempotent by stable id, bounded,
 * duplicate-protected, and corruption-safe (a malformed store resets to empty
 * rather than crashing the app). Only pending candidate captures are stored;
 * rows are deleted on ack. Raw bodies are never logged.
 */
class DurableCaptureQueue private constructor(private val prefs: SharedPreferences) {

    companion object {
        private const val PREFS_NAME = "mali_capture_queue_v1"
        private const val KEY_ITEMS = "items"
        /** Cap the backlog so a runaway producer can't grow storage unbounded. */
        private const val MAX_ITEMS = 200

        @Volatile
        private var instance: DurableCaptureQueue? = null

        fun get(context: Context): DurableCaptureQueue {
            return instance ?: synchronized(this) {
                instance ?: DurableCaptureQueue(
                    context.applicationContext
                        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE),
                ).also { instance = it }
            }
        }

        /** ISO-8601 UTC timestamp — the format the Dart parser expects
         *  (DateTime.tryParse). API-safe (no java.time). */
        fun isoNow(): String {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            fmt.timeZone = TimeZone.getTimeZone("UTC")
            return fmt.format(Date())
        }
    }

    data class Item(
        val id: String,
        val text: String,
        val sender: String?,
        val source: String, // "share" | "sms"
        val receivedAt: String, // ISO-8601 UTC
    )

    @Synchronized
    private fun readAll(): MutableList<Item> {
        val raw = prefs.getString(KEY_ITEMS, null) ?: return mutableListOf()
        return try {
            val array = JSONArray(raw)
            val out = ArrayList<Item>(array.length())
            for (i in 0 until array.length()) {
                val o = array.getJSONObject(i)
                out.add(
                    Item(
                        id = o.getString("id"),
                        text = o.getString("text"),
                        sender = if (o.isNull("sender")) null else o.optString("sender"),
                        source = o.optString("source", "share"),
                        receivedAt = o.optString("receivedAt", ""),
                    ),
                )
            }
            out
        } catch (_: Throwable) {
            // Corruption safety: never let a malformed store crash capture —
            // drop it and start clean rather than throwing on every read.
            prefs.edit().remove(KEY_ITEMS).apply()
            mutableListOf()
        }
    }

    @Synchronized
    /**
     * MALI-068n: writes are SYNCHRONOUS (`commit()`), not `apply()`. A broadcast
     * receiver / App-Intent process can be killed the instant it returns, so the
     * enqueue and the per-item acknowledge must be durably on disk before the
     * caller proceeds — otherwise a captured message is lost, or a re-delivered
     * one resurrects an already-acknowledged item. Returns whether the write was
     * durably committed.
     */
    private fun writeAll(items: List<Item>): Boolean {
        val array = JSONArray()
        items.forEach { item ->
            val o = JSONObject()
            o.put("id", item.id)
            o.put("text", item.text)
            if (item.sender != null) o.put("sender", item.sender)
            o.put("source", item.source)
            o.put("receivedAt", item.receivedAt)
            array.put(o)
        }
        return prefs.edit().putString(KEY_ITEMS, array.toString()).commit()
    }

    /**
     * Idempotent enqueue: a duplicate id (or identical text+source) is ignored.
     * Returns true only when the new item was durably persisted before return.
     */
    @Synchronized
    fun enqueue(item: Item): Boolean {
        val items = readAll()
        if (items.any { it.id == item.id }) return false
        if (items.any { it.text == item.text && it.source == item.source }) return false
        if (items.size >= MAX_ITEMS) items.removeAt(0) // drop oldest, keep newest
        items.add(item)
        return writeAll(items) // false if not durably committed
    }

    /** Non-destructive read of the whole queue as a JSON array (null if empty). */
    @Synchronized
    fun peekJson(): String? {
        val items = readAll()
        if (items.isEmpty()) return null
        val array = JSONArray()
        items.forEach { item ->
            val o = JSONObject()
            o.put("id", item.id)
            o.put("text", item.text)
            if (item.sender != null) o.put("sender", item.sender)
            o.put("source", item.source)
            o.put("receivedAt", item.receivedAt)
            array.put(o)
        }
        return array.toString()
    }

    /**
     * Destructive drain — returns the whole queue as JSON and clears it.
     * Only for the legacy `consumePendingSharedMessages` compat path; the
     * durable path is peek + per-item acknowledge.
     */
    @Synchronized
    fun drainJson(): String? {
        val json = peekJson() ?: return null
        prefs.edit().remove(KEY_ITEMS).commit() // durable clear before returning
        return json
    }

    /**
     * Remove exactly the acknowledged id. Returns true only when the removal was
     * durably committed, so a kill after ack never resurrects the item.
     */
    @Synchronized
    fun acknowledge(id: String): Boolean {
        val items = readAll()
        val removed = items.removeAll { it.id == id }
        if (!removed) return false
        return writeAll(items)
    }

    /**
     * MALI-054n: purge ALL queued capture payloads so a previous account's bank
     * messages can never be imported under a new identity. Uses commit()
     * (synchronous + verified) rather than apply(), because the purge runs on a
     * destructive user-lifecycle boundary whose success the caller must be able
     * to confirm before admitting a new user. Returns true on verified removal.
     */
    @Synchronized
    fun purge(): Boolean {
        return prefs.edit().remove(KEY_ITEMS).commit()
    }

    @Synchronized
    fun size(): Int = readAll().size
}
