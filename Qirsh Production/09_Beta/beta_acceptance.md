# Beta Acceptance Criteria

Objective conditions for moving from internal beta to store submission.

## BLOCKING — must be zero

| # | Condition |
|---|---|
| B1 | Any money value displayed differs from the source bank message |
| B2 | Any crash on launch, onboarding, or auth |
| B3 | Data loss on sign-out, restore, or upgrade |
| B4 | Consent default is anything other than OFF |
| B5 | Legal links do not open the live pages |
| B6 | Capture silently fails on a supported bank |
| B7 | Backup restores incorrect money values |
| B8 | Biometric lock can be bypassed |
| B9 | UX-035 unverified, or large values wrong/illegible on device |
| B10 | An Edge Function worker accepts an unauthenticated request |

## HIGH — fix before production, may pass beta

| # | Condition |
|---|---|
| H1 | A notification lacks the context to identify what triggered it |
| H2 | RTL layout clipping on any money surface |
| H3 | A destructive action is unconfirmed |
| H4 | Performance: any core screen takes >2s on a mid-range device |
| H5 | A section vanishes with no explanation when empty |

## NON-BLOCKING — log and schedule

Visual polish, copy refinement, minor spacing, nice-to-have affordances.

## Exit criteria

- [ ] Zero BLOCKING open
- [ ] All HIGH triaged with an owner and a decision
- [ ] ≥1 week of internal use on both platforms
- [ ] ≥2 real banks verified per platform
- [ ] Crash-free sessions >99%
- [ ] Device QA signed off on both platforms
