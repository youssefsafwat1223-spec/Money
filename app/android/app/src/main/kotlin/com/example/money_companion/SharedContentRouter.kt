package com.example.money_companion

/**
 * COUPONS Phase 5 — deciding where shared text goes, at the native boundary.
 *
 * A MIRROR of `lib/features/coupons/shared_content_router.dart`. The
 * classification has to happen HERE, before anything is enqueued, because the
 * whole point is that a merchant URL never enters the financial capture queue —
 * and by the time Dart sees it, it already has.
 *
 * The Dart copy remains the specification; a Dart test asserts the two agree on
 * a shared fixture set. Two implementations of one rule is the same trade as the
 * merchant alias key: unavoidable, and controlled by testing them against the
 * same cases rather than against each other.
 *
 * ## The bias is toward CAPTURE
 *
 * Only text that is essentially nothing but a URL becomes an offer intent. A
 * bank message that happens to quote a link is still a bank message, and
 * misrouting one silently loses a transaction the user expected to be recorded —
 * a worse failure than showing them a merchant page they did not ask for.
 */
object SharedContentRouter {

    sealed class Result {
        data class Capture(val text: String) : Result()
        data class OfferUrl(val sanitizedUrl: String, val host: String) : Result()
        object Ignored : Result()
    }

    /** Longer than this is prose containing a link, not a shared link. */
    private const val MAX_URL_SHARE_LENGTH = 512

    private val URLISH = Regex("""^\s*(?:https?://)?[^\s]+\.[^\s]{2,}\s*$""")
    private val HAS_HTTP_SCHEME = Regex("""^\s*https?://""", RegexOption.IGNORE_CASE)

    /**
     * ANY scheme, checked BEFORE http is prepended.
     *
     * `mailto:a@b.com` with `https://` glued on front parses as userInfo
     * `mailto:a` and host `b.com`, so a shared email address would have been
     * classified as an offer link to the recipient's domain. The Dart test that
     * expected mailto to reach capture is what surfaced it.
     */
    private val ANY_SCHEME = Regex("""^\s*[a-z][a-z0-9+.\-]*:""", RegexOption.IGNORE_CASE)

    private val HOST_SHAPE =
        Regex("""^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$""")

    fun classify(raw: String?): Result {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return Result.Ignored

        if (text.contains('\n') || text.length > MAX_URL_SHARE_LENGTH ||
            !URLISH.matches(text)
        ) {
            return Result.Capture(text)
        }
        if (ANY_SCHEME.containsMatchIn(text) && !HAS_HTTP_SCHEME.containsMatchIn(text)) {
            return Result.Capture(text)
        }

        val withScheme = if (HAS_HTTP_SCHEME.containsMatchIn(text)) text else "https://$text"
        val uri = try {
            java.net.URI(withScheme)
        } catch (_: Exception) {
            return Result.Capture(text)
        }

        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return Result.Capture(text)
        // Credentials in a URL are not something a merchant share carries, and
        // storing one would persist somebody's password.
        if (!uri.userInfo.isNullOrEmpty()) return Result.Capture(text)

        var host = uri.host?.lowercase() ?: return Result.Capture(text)
        if (host.startsWith("www.")) host = host.substring(4)
        if (host.endsWith(".")) host = host.dropLast(1)
        if (!HOST_SHAPE.matches(host)) return Result.Capture(text)

        // REBUILT from parts, never a substring of the original — that is what
        // guarantees no query parameter or fragment survives by accident. A
        // shared shopping URL routinely carries a session id, a cart id, the
        // sharer's referral code and analytics that identify them; none of it is
        // needed to know which merchant this is.
        val path = uri.path.orEmpty().ifEmpty { "/" }
        val sanitized = "https://" + (uri.host?.lowercase() ?: host) + path

        return Result.OfferUrl(sanitizedUrl = sanitized, host = host)
    }
}
