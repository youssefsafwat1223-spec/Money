# Physical-Device QA

Run on **both** a real iPhone and a real Android. Platform-specific rows are in
[`../05_Apple/physical_device_qa.md`](../05_Apple/physical_device_qa.md) and
[`../06_Android/physical_device_qa.md`](../06_Android/physical_device_qa.md).

**Capabilities stay OFF throughout.** Cloud financial sync is inactive by design;
do not activate it to "test" it here.

## Severity

| Level | Meaning |
|---|---|
| **BLOCKING** | release does not proceed |
| **HIGH** | fix before production; may pass internal beta |
| **NON-BLOCKING** | log and schedule |

---

## 1. Install and launch

| # | Test | Pass | Severity |
|---|---|---|---|
| 1.1 | Fresh install, cold launch | opens within ~3s, no crash | BLOCKING |
| 1.2 | Relaunch after force-quit | opens to a usable state | BLOCKING |
| 1.3 | Launch offline | app works; cloud features degrade quietly | BLOCKING |

## 2. Onboarding

| # | Test | Pass | Severity |
|---|---|---|---|
| 2.1 | Full flow: story → brand → auth → setup | completes; step dots and «خطوة N من 3» correct | BLOCKING |
| 2.2 | Back navigation mid-flow | returns without losing entered data | HIGH |
| 2.3 | Country/currency selection | base currency persists | BLOCKING |
| 2.4 | Consent copy | states clearly what is on and off by default | BLOCKING |

## 3. Authentication

| # | Test | Pass | Severity |
|---|---|---|---|
| 3.1 | Sign in with Apple | succeeds; user appears in Supabase | BLOCKING |
| 3.2 | Sign in with Google | succeeds (needs "skip nonce checks" ON) | BLOCKING |
| 3.3 | Sign out with unsynced data | **warns and offers to keep data** (MALI-053n) | BLOCKING |
| 3.4 | Re-login | same user id, data intact | BLOCKING |

## 4. Exact money — the highest-risk area

| # | Test | Pass | Severity |
|---|---|---|---|
| 4.1 | Add `12.345` in a KWD account | displays `12.345`, **not** `12.34` or `12.35` | BLOCKING |
| 4.2 | Add `0.01` | displays `0.01` | BLOCKING |
| 4.3 | Budget card: spend + remaining vs limit | the three figures **reconcile exactly** (UX-001) | BLOCKING |
| 4.4 | Refund in Reports | gross − refunds = net, all three shown | BLOCKING |
| 4.5 | Account balances | never summed across currencies | BLOCKING |
| 4.6 | Large value on Home hero | every digit legible and correct — see UX-035 | BLOCKING |

## 5. Parser and capture

| # | Test | Pass | Severity |
|---|---|---|---|
| 5.1 | Real bank SMS from bank A | amount, merchant, date exactly match the message | BLOCKING |
| 5.2 | Real bank SMS from bank B | as above | BLOCKING |
| 5.3 | Non-transaction SMS (OTP, marketing) | ignored, no transaction created | BLOCKING |
| 5.4 | Duplicate message | flagged, not double-counted | BLOCKING |
| 5.5 | Capture notification content | names the card; category only when actually known | HIGH |

## 6. Core surfaces

| # | Test | Pass | Severity |
|---|---|---|---|
| 6.1 | Accounts list | balances shown; negatives distinguished | BLOCKING |
| 6.2 | Cards: link, unlink, «بدون بطاقة» | account does **not** change with the card (UX-034) | BLOCKING |
| 6.3 | Budgets: create, edit, delete | delete confirmed; figures reconcile | BLOCKING |
| 6.4 | Goals: deadline and required rate | shown and arithmetically right (UX-025) | HIGH |
| 6.5 | Subscriptions: account scoping named | header names the scoping account (UX-024) | HIGH |
| 6.6 | Plans: edit leads, delete one level in | delete still confirmed (UX-027) | HIGH |
| 6.7 | Transactions: pending filter | «قيد المراجعة» chip isolates them (UX-016) | HIGH |
| 6.8 | Home sections when empty for an account | header stays with an explanatory line (UX-010) | HIGH |

## 7. Notifications

| # | Test | Pass | Severity |
|---|---|---|---|
| 7.1 | Budget alert names budget + account + threshold | does not read as belonging to an unrelated purchase (UX-037) | HIGH |
| 7.2 | APNs foreground / background / terminated | delivered in all three | BLOCKING |
| 7.3 | Message centre rows are dated | every row dated (UX-031) | HIGH |

## 8. Backup and restore

| # | Test | Pass | Severity |
|---|---|---|---|
| 8.1 | Export ZIP | file produced | BLOCKING |
| 8.2 | Restore on a clean install | all data returns; **money values byte-identical** | BLOCKING |
| 8.3 | Export CSV | opens in a spreadsheet, amounts exact | HIGH |
| 8.4 | Restore with a wrong passphrase | fails clearly, no partial write | BLOCKING |

## 9. Consent and privacy

| # | Test | Pass | Severity |
|---|---|---|---|
| 9.1 | Cloud sync default | **OFF** on a fresh install | BLOCKING |
| 9.2 | AI consent default | **OFF** | BLOCKING |
| 9.3 | Revoke consent | egress stops immediately | BLOCKING |
| 9.4 | Privacy screen links | open the live legal pages | BLOCKING |
| 9.5 | Delete account | confirmed, and actually deletes | BLOCKING |

## 10. RTL, locale, resilience

| # | Test | Pass | Severity |
|---|---|---|---|
| 10.1 | Arabic RTL throughout | no clipped or mirrored money values | BLOCKING |
| 10.2 | English LTR | layout correct | HIGH |
| 10.3 | Negative amounts in RTL | minus stays attached to the number | BLOCKING |
| 10.4 | Airplane mode mid-sync | queues, no data loss, no crash | BLOCKING |
| 10.5 | Background 30 min, resume | state intact, lock re-prompts | HIGH |
| 10.6 | Low battery / low storage | no corruption | HIGH |

## Sign-off

- [ ] Every BLOCKING row passes on iPhone
- [ ] Every BLOCKING row passes on Android
- [ ] UX-035 verified with screenshots
- [ ] HIGH failures triaged with owners
- [ ] Device models, OS versions and app build recorded
