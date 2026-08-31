# Android Auto-SMS — Physical Device QA

Required before submitting the Play Permissions Declaration. A debug build is
sufficient; no signed release is needed.

**Two device states that are NOT the same thing:**

| State | How | Does the receiver fire? |
|---|---|---|
| **Process not running** | swipe the app away, or let Android reclaim it | **YES** — a manifest-declared receiver is started by the system |
| **Force Stop** | Settings → Apps → Qirsh → Force Stop | **NO** — Android puts the app in a stopped state and withholds broadcasts until the user launches it again |

Force Stop suppression is OS behaviour, not a Qirsh defect, and it must not be
presented to a reviewer as a bug or promised as working. Test both and record
them separately.

## Setup

Two SIMs or a second phone to send test messages. Compose bank-style texts that
match your real bank's format. Do **not** wait for real bank traffic — you
cannot control its timing and you will not be able to test the negatives.

## Procedure

| # | Step | Expected |
|---|---|---|
| 1 | Clean install (uninstall first — do not upgrade) | app launches |
| 2 | Open capture settings before touching anything | auto-capture **OFF** |
| 3 | Tap the toggle | **disclosure appears BEFORE any system dialog** |
| 4 | Decline the disclosure | **no system dialog appears**; toggle stays off |
| 5 | Tap again, accept the disclosure, then **deny** the OS dialog | toggle stays off; app fully usable |
| 6 | Tap again | disclosure, then the OS dialog appears again |
| 7 | Deny with "don't ask again", then tap again | app offers the **Settings** route, not a dead button |
| 8 | Grant in Settings, return, leave toggle **OFF**; send a bank SMS | **nothing captured** — permission is not consent |
| 9 | Turn the toggle **ON** | reports enabled |
| 10 | Send a bank SMS, app in **foreground** | captured |
| 11 | Send a bank SMS, app in **background** | captured |
| 12 | Swipe the app away (**process not running**), send a bank SMS, then open the app | captured — this is the case that justifies a manifest receiver |
| 12b | **Force Stop**, send a bank SMS, then open the app | **not captured** — expected OS behaviour; record it, do not file it as a bug |
| 13 | Send a **multipart** bank SMS (>160 chars) | **one** capture, text reassembled in order |
| 14 | Send a personal SMS **from a phone number** containing the word "card" | **not captured, not stored** |
| 15 | Send an OTP from a bank sender ID | **not captured** |
| 16 | Revoke the permission in system settings, send a bank SMS | **not captured**; toggle reflects disabled |
| 17 | Re-grant, re-enable, send **the same SMS twice** | **exactly one** transaction |
| 18 | Open the transactions list | the captured row is present with the right amount, date and merchant |
| 19 | With the permission **revoked**, share a message to Qirsh | still captured — share needs no permission |
| 20 | Reboot the phone, do **not** open the app, send a bank SMS | captured (receiver starts cold) |

## Recording

For each row: pass/fail, device model, Android version, and for failures the
exact message text with personal details removed. Rows **3, 12, 12b, 14, 15, 16
and 17** are the ones the Play reviewer cares about, and 3/14/16 are the ones to
film for the review video.

## Known limitation

Steps 13–17 exercise the Kotlin prefilter, which has **no automated test** — the
project has no JVM or instrumentation test source set for Android. This manual
matrix is currently the only execution evidence for that code. Losing it means
losing the only proof the filter behaves as described.
