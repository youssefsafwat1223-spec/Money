# Play Internal Testing

## Prerequisites

- Signed AAB (fingerprint verified against the keystore)
- Data safety and permission declarations complete
- Legal URLs live

## Setup

Play Console → Testing → **Internal testing** → Create release. Up to 100
testers by email; available within minutes, no review wait.

## Initial state

Same as TestFlight: sync flags off, capabilities `unknown`. State it in the
release notes.

## Test matrix

| Dimension | Cover |
|---|---|
| Vendors | **Samsung, Xiaomi and stock** — they differ on the three things Qirsh depends on |
| Android versions | 13, 14, 15 (notification-permission behaviour changed at 13) |
| Locale | ar (RTL) and en (LTR) |
| Font size | default and maximum |
| Theme | light and dark |

## Vendor differences worth budgeting time for

Samsung One UI and Xiaomi MIUI diverge from stock on background execution,
notification access and biometrics. A Pixel-only pass is not coverage.

## Acceptance

- [ ] `../08_Device_QA/device_qa_checklist.md` BLOCKING rows all pass
- [ ] `../06_Android/physical_device_qa.md` rows all pass
- [ ] Capture works after a reboot and with the app swiped away
- [ ] No ANR or crash affecting >1% of sessions
