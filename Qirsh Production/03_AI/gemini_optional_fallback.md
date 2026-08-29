# Optional Fallback — Gemini

**Gemini is optional. Qirsh works normally without it.**

## Current implementation state

Wired and gated. `SupabaseAiParserClient` is constructed only when
`SupabaseConfig.isConfigured` (`app/lib/core/di/app_providers.dart:1219`,
`captured_message_processor.dart:122`) and calls the `parse-sms` Edge Function.

**The app never holds a Gemini key.** The key lives server-side as
`GEMINI_API_KEY`, used by `parse-sms`, `bank-discovery` and `process-ios-sms`.

## When it may be invoked

Only when the deterministic parser cannot resolve a message. It is an escalation
path for unparseable input, not a step in the normal pipeline.

## Consent boundary

`loadAiConsent` reads `settings.aiConsentGranted`. Egress is additionally gated
by `ConsentAuthority` at `EgressClass.aiProcessing`, which fails closed with the
reason `ai_consent_off` when `cloudProcessingEnabled` is false.

**Two independent gates.** Consent off means no call, regardless of key state.

## Payload minimisation

The message is sanitised on-device, then **re-sanitised server-side**
(`reSanitize`) before the model sees it. Only a payload **hash** is stored for
idempotency — never the raw SMS — with a bounded TTL.

## Key handling

Server-only. Never in the binary, never in a `--dart-define`, never in a log.
The client authenticates to the Edge Function with a Supabase JWT plus a device
secret.

## Response validation

Structured and schema-checked. A malformed or unexpected response is discarded
rather than partially trusted.

## Failure behaviour

| Condition | Behaviour |
|---|---|
| Key absent | `upstream_unavailable`, retryable — **local operation continues** |
| Timeout | `fetchWithTimeout` bounds it; non-fatal |
| Quota exhausted | upstream error surfaces as retryable; non-fatal |
| Malformed response | discarded |
| Replayed request id with a different payload | `request_replay_mismatch` |

Idempotency (MALI-060n): a stable client `request_id` means a retry never repeats
the paid call.

## Financial authority — none

Gemini may **never** independently establish amount, currency, exact Money,
direction, account identity or card identity. The deterministic parser remains
authoritative for all of them. Gemini's influence is bounded by the same write
fence as the local classifier.

## Disabling it completely

```bash
supabase secrets unset GEMINI_API_KEY
```

Or simply never set it. The three functions then return `upstream_unavailable`
and the app continues on the deterministic parser plus the on-device classifier.

**Shipping without Gemini is a supported configuration**, not a degraded one.
