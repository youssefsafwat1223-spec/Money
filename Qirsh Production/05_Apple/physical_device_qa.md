# iPhone Device QA

Full matrix: [`../08_Device_QA/device_qa_checklist.md`](../08_Device_QA/device_qa_checklist.md).
iOS-specific items a simulator cannot exercise.

| # | Test | Pass criteria |
|---|---|---|
| I1 | Face ID unlock, plus cancel and fallback | unlocks; cancel returns to the lock screen without exposing data |
| I2 | Share-sheet extension from Messages | a bank message shared into Qirsh is captured |
| I3 | Shortcut `BankMessageShortcuts` end-to-end (H-19) | the App Intent runs and produces a transaction |
| I4 | Shared Keychain across app + extension (MALI-031) | the extension reads the shared device secret; no re-registration |
| I5 | APNs foreground / background / **terminated** | delivered in all three — they are three different code paths |
| I6 | Lock-screen actions «تأكيد ✓» / «تجاهل» | both act correctly without unlocking |
| I7 | App Group container handoff | capture queued by the extension appears in the app |
| I8 | Biometric lock after backgrounding | re-prompts after the configured interval |
| I9 | Dynamic Island / notch clearance on a Pro device | header clears the island; `useSafeAreaTop` uses the real inset |
| I10 | Dynamic Type at maximum | money surfaces stay legible — see `UX_035_verification.md` |

## Why a simulator is not enough

Face ID is synthetic; push behaves differently; App Groups and Keychain groups
need a real team prefix; App Intents need a device; the lock screen is not
simulated. Every row above fails to be *evidence* on a simulator even when it
appears to pass.
