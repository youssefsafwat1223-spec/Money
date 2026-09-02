# Qirsh — master roadmap

**As of 2026-09-02.** What remains, in dependency order. Anything not here is
either done or deliberately out of scope.

## Now — unblocked, no external dependency

Nothing. Every executable engineering task with no external dependency is
complete. This is what ENGINEERING COMPLETE means.

The nearest candidates, all deliberately deferred with reasons in
`DECISIONS.md`, are: wiring the Proof-Carrying engine (D-13), wiring the
affiliate click gateway (D-14), and the two consistency fixes below.

## Next — small, owned, non-blocking

| Item | Severity | Note |
|---|---|---|
| `set_default_account` consent gate | MEDIUM | Gates on transport capability while its sibling push/pull services in the same pipeline gate on consent. Fix the inconsistency; it is one path in `accounts_backfill_service.dart`. |
| `record_metric` client consent gate | MEDIUM | Awaited from bootstrap, so a consent read there must survive a cold start with no settings loaded. That is the reason it was left; it is solvable. |
| iOS share extension display name | LOW | «إضافة رسالة بنك» is now inaccurate for a URL share. A product naming decision, left to the owner. |
| Relocate `android/key.properties` | LOW | Gitignored and asserted so, but real key material in a source tree is one archive away from travelling. |
| JVM test source set for Android | LOW | Kotlin is covered by structural source assertions rather than execution. |
| macOS target cannot open the database | LOW | `macos/Runner/*.entitlements` has no keychain entitlement, so the SQLCipher key cannot be read under the sandbox and `database_open` fails. macOS is not a shipping target, but it is the ONLY runtime surface on this machine. Fixing it needs a real signing identity — an ad-hoc build expands `$(AppIdentifierPrefix)` to nothing and is killed at launch. Worth doing: it would turn "no runtime QA is possible" into "a smoke run is possible". |

## Blocked on the owner

In the order that unblocks the most:

1. **Read the production migration ledger** (RB-4) — unblocks every backend
   deployment decision and resolves whether account deletion fully erases.
2. **Connect an Android device** (RB-5) — unblocks BETA READY, the SMS device
   matrix, and banner QA.
3. **Reconcile the three SMS disclosure documents, then submit the Play
   declaration and Data Safety form** (RB-6) — unblocks Android publication.
4. **Restore Apple portal access** — unblocks iOS signing, APNs, and iOS device
   QA.
5. **Create AdMob units + publish `app-ads.txt`** — unblocks ad revenue.
6. **Contract an affiliate network** — unblocks coupons monetization; read the
   attribution and browser-extension clauses before building further.

## Deferred by decision, not by capacity

- Safari Web Extension (D-15) — three conditions, all required together.
- Proof-Carrying activation (D-13) — an integration change, to be done
  deliberately with shadow-only validation before any money-bearing decision.
- Affiliate click tracking (D-14) — when a network exists.
- Personalized advertising / ATT (D-6) — a separately approved configuration.

## Explicitly not planned

New features. The objective is to finish Qirsh, not extend it. Work qualifies
only if it closes an implementation gap, closes a release blocker, completes an
already-approved feature, fixes a security or privacy issue, fixes a broken UX
path, or is required by store policy.
