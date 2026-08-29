# Android Device QA

Full matrix: [`../08_Device_QA/device_qa_checklist.md`](../08_Device_QA/device_qa_checklist.md).
Android-specific items that a simulator or an iPhone cannot cover.

| # | Test | Pass criteria |
|---|---|---|
| A1 | Notification-listener permission: grant, revoke, re-grant | capture starts/stops accordingly; no crash on revoke |
| A2 | Real bank SMS captured end-to-end | transaction appears with the **exact** amount from the message |
| A3 | Background capture with the app swiped away | message still captured |
| A4 | Battery-optimisation exemption prompt | prompt appears; denying degrades gracefully with an explanation |
| A5 | Biometric prompt across vendor skins | works on Samsung One UI and Xiaomi MIUI — they differ meaningfully from stock |
| A6 | SQLCipher open on a low-RAM device | opens without ANR |
| A7 | Locale switch ar ⇄ en | full RTL/LTR relayout, no clipping |
| A8 | Install from the signed AAB | installs; Play Protect does not warn |
| A9 | Reboot | scheduled reminders survive (`RECEIVE_BOOT_COMPLETED`) |
| A10 | Doze mode overnight | pending notifications deliver on wake |

## Vendor skins matter

Samsung and Xiaomi diverge from stock Android on background execution,
notification access and biometrics — the three things Qirsh most depends on.
Testing only on a Pixel is not sufficient coverage.
