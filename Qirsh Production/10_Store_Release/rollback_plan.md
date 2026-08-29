# Store Rollback

## Google Play

**Halt the rollout** — Release → Production → Halt. Stops new users receiving the
build; existing installs keep it.

**Roll back** — resume the previous release at the desired percentage. Play does
not "un-install" a version; you ship the old one forward.

**A bad version cannot be recalled.** Anyone who already updated stays on it
until they update again. This is why staged percentages exist.

## App Store

**Pause a phased release** from App Store Connect. **Remove from sale** in an
emergency — drastic and visible.

**Expedited review** exists for critical fixes but is discretionary and not a
plan you can rely on.

## The faster levers — prefer these

Because a store rollback is slow and partial, prefer:

| Problem | Lever | Speed |
|---|---|---|
| Money syncing wrong | `ledger_push_sync` / `ledger_pull_sync` off | minutes |
| A parser mis-reading | that parser's `validation_status` → `pending` | minutes |
| Gemini misbehaving | `supabase secrets unset GEMINI_API_KEY` | minutes |
| Everyone must upgrade | `arm_force_update()` | next launch |

Most incidents are better solved server-side than by a store rollback. Reserve
the store lever for a defect that is purely client-side and unreachable by flag.

See [`../11_Rollback_Recovery/`](../11_Rollback_Recovery/).
