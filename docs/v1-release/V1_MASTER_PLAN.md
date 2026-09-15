# V1 Master Plan

Authoritative plan from current state to iOS release candidate.
Frozen after Phase 5. Changes to scope require a V1_DECISION_LOG entry.

**Written:** 2026-09-15 · **Base:** `5edfdb6e` on `feat/phase1-data-integrity`

---

## 0. The constraint that shapes this plan

**EB-001 (Xcode 27.0 licence unaccepted) blocks every iOS capability**:
Simulator, iOS builds, `integration_test`, the release archive, and screenshot
capture. It needs `sudo` and is the acceptance of a legal agreement in the
owner's identity — owner-only on both counts.

This plan is therefore split so that **no Dart-side work waits on it**:

- **Track 1 — Unblocked now.** Everything expressible in Dart/SQL/config, with
  unit and widget proof. This is the large majority of V1 engineering.
- **Track 2 — Queued behind EB-001.** Simulator visual acceptance, the release
  archive, and the final-UI screenshots that Required Change 5 depends on.

Track 2 work is *prepared* (code written, tests written, checklists filled) so
that when EB-001 clears, it is execution and evidence capture — not design.

**The release candidate cannot be declared ready while EB-001 is open.** That is
stated plainly rather than worked around.

---

## 1. Scope

### In scope — required product changes (charter-mandated)

| # | Change | Track |
|---|---|---|
| RC-1 | Smoking/tobacco default category | 1 |
| RC-2 | Remove the streak reminder | 1 |
| RC-3 | Annual / year reporting | 1 (visual acceptance → 2) |
| RC-4 | Daily reminder at 22:00, incl. migration off the old time | 1 |
| RC-5 | Guidance: coach marks + Help surface | 1 (screenshots → 2) |

### In scope — release engineering

- 45 P0 + UNVERIFIED invariants (see V1_AUDIT_RECONCILIATION §1)
- Analyzer to zero (repo gate; 25 issues introduced by the SDK upgrade)
- The harness defect in `destructive_phase_test.dart` — a test that cannot fail
- Feature activation resolution — every flag, route, and hidden surface
- Arabic (Fusha) / English closure, RTL + LTR
- UI Atlas reconciliation against current Flutter
- Notification inventory and proof
- Secret hygiene (QA defines out of build configuration)
- App Store checklist
- Coupons: correctness only, **no redesign**

### Explicitly out of scope

- Google Play submission (owner-deferred)
- Coupons redesign (charter-protected)
- Activating exact financial push/pull (stays dark and truthfully documented)
- Migration 0100 (stays deferred)
- The owner's in-flight dashboard daily-allowance work (preserved untouched)
- P2/P3 polish that does not serve a gate

---

## 2. Execution order

Priority is by risk and by unblocking, not by UI order.

**Stage A — Foundation (hours 0–4)**
1. Environment repair + baseline. *(done)*
2. Analyzer to zero — read each of the 9 money-path warnings rather than
   suppressing them; they sit in push services.
3. Fix `destructive_phase_test.dart` so it asserts. A test that cannot fail is
   worse than no test: it launders absence of evidence into a PASS.

**Stage B — Required product changes (hours 4–16)**
RC-2 (removal, self-contained) → RC-1 (category, touches catalogue +
localization) → RC-4 (reminder time + reschedule migration) → RC-3 (annual
reporting, reuses the reporting architecture) → RC-5 (guidance framework).

Each lands with unit/widget proof. Visual acceptance is queued to Track 2.

**Stage C — P0 closure (hours 12–32, parallel with B where files do not
overlap)**
Ordered by blast radius:
1. Authorization — `register-device` credential minting, `sync-captures` row
   ownership, RLS coverage, `feature_flag_overrides` write surface
2. Privacy egress — consent gating on every egress point; the three divergent
   sanitizers, weakest of which serves the off-device AI path
3. Money/data loss — sign-out wipe ordering, parked-mutation destruction,
   restore reconcile
4. Dedup/idempotency — the canonical identity rule and its delivery paths

**Stage D — Closure (hours 32–44)**
Feature activation matrix · localization closure · notification matrix ·
App Store checklist · secret scrub · Android compatibility check.

**Stage E — Release candidate (blocked by EB-001)**
Simulator walk · UI acceptance · guidance screenshots · archive · validation.

---

## 3. Definition of done

No item is DONE on code alone. Applicable proof is required: unit/widget test,
runtime evidence, localization evidence, review. A gate line may be marked PASS
only by naming the test that exercises the runtime path — never by an exit code
and never by a source-text grep.

Where proof is impossible in this environment, the item is recorded
**BLOCKED**, never PASS. `BLOCKED ≠ PASS`.

---

## 4. Agent routing

Per charter. Opus orchestrates and owns integration. Implementation is delegated
where a task is well-scoped and file ownership is clean; reasoning-heavy
security/privacy/money questions go to a senior reviewer; an independent
red-team pass reviews the final diff. Reviewer unavailability is recorded and
deferred — it never stops execution.
