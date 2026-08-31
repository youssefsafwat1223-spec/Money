# Play Data Safety — DRAFT

**NOT SUBMITTED.** Must match the shipped manifest and the live privacy policy
exactly — Google cross-checks all three, and Data Safety answers are attested.

## Data collected

| Type | Collected | Shared | Purpose | Optional | Notes |
|---|---|---|---|---|---|
| **SMS messages** | Yes | **No** | App functionality | **Yes** — optional feature, off by default | Filtered on device; only financial messages retained |
| Financial info (transactions) | Yes | No | App functionality | No | Derived from captured messages and manual entry |
| App activity | Yes | No | App functionality, analytics | Yes | Capture reliability telemetry |
| Personal identifiers (email) | Yes | No | Account management | No | Sign-in only |

## Not collected

Location, contacts, photos/videos, audio, health, calendar, browsing history,
and — importantly — **no SMS inbox history** (`READ_SMS` is not declared).

## Security practices

- **Encrypted in transit** — yes, HTTPS everywhere.
- **Encrypted at rest on device** — SQLCipher, key held in the Android Keystore.
- **Users can request deletion** — yes; the app has an account-deletion path.
- **Data can be deleted from the device** — yes.
- **Committed to the Play Families policy** — n/a.

## Answers that must stay true

| Question | Answer | Why it must not drift |
|---|---|---|
| Is SMS data shared with third parties? | **No** | sharing would void the money-management exception |
| Used for advertising or marketing? | **No** | the app has ads, but they are never targeted from transaction data |
| Used for profiling? | **No** | stated in the privacy policy |
| Is collection optional? | **Yes** | the feature is opt-in and off by default |

⚠️ **Consistency is checked.** The Data Safety form, the shipped manifest and
`https://qirsh.site/privacy` must agree. Under-declaring is a policy violation;
over-declaring invites scrutiny for data the app does not touch.
