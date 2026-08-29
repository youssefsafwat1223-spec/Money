# AI Architecture

| Layer | Role | Cost | Required? |
|---|---|---|---|
| [On-device classifier](local_classifier.md) | **primary** | zero | yes — always available |
| [Gemini](gemini_optional_fallback.md) | optional fallback for unparseable messages | paid per request | **no** |

The deterministic parser remains authoritative for all financial truth — amount,
currency, direction, account and card identity. Neither AI layer can override it.

**If `GEMINI_API_KEY` is absent, Qirsh works normally.** Shipping without it is a
supported configuration.
