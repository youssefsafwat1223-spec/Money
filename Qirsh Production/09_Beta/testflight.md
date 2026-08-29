# TestFlight

## Prerequisites

- Backend provisioned (runbook Phase 3)
- Signed IPA uploaded and processed
- Legal URLs live

## Initial state — say this in the tester notes

- Sync feature flags **off**
- Capabilities `unknown` → **cloud financial sync inactive by design**
- Gemini optional; state whether the key is set

Testers will otherwise report "sync doesn't work" as a bug.

## Internal testing

App Store Connect → TestFlight → Internal Testing. Up to 100 App Store Connect
users, **no Beta App Review required** — start here.

## External testing

Needs Beta App Review (usually ~24h). Requires:
- the privacy policy URL
- a demo account — **reviewers cannot receive real bank SMS**
- notes explaining on-device capture and default-off sync

## Test matrix

| Dimension | Cover |
|---|---|
| Devices | one notched/Dynamic Island Pro, one non-Pro, one iPad if supported |
| iOS versions | current and current−1 |
| Locale | ar (RTL) and en (LTR) |
| Text size | default and maximum |
| Theme | light and dark |
| Network | online, offline, flaky |

## Acceptance

- [ ] `../08_Device_QA/device_qa_checklist.md` BLOCKING rows all pass
- [ ] UX-035 verified
- [ ] No crash affecting >1% of sessions
- [ ] Capture works on real messages from ≥2 banks
- [ ] ≥1 week of internal use with no BLOCKING defect open
