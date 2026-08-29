# Phase J — Authoritative QA Source

These are copies of the QA artifacts Phase J closed against. They lived only in
`demo-docker/`, which is an untracked local demo/working directory — so the
authoritative record of what was found would have been lost with that folder.

| File | Role |
|---|---|
| `UI_UX_REDESIGN_BACKLOG.md` | **the authoritative list** — 37 UX findings (UX-001…UX-037) |
| `DEMO_GUIDED_QA.md` | the guided QA session log the findings originated from |
| `UI_REDESIGN_IMPLEMENTATION_PLAN.md` | cross-checked during source recovery |

**Closure against this list:** [`../../audit/QIRSH_PHASE_J_UIUX_CLOSURE.md`](../../audit/QIRSH_PHASE_J_UIUX_CLOSURE.md)
— 39/39 closed (37 findings + R-8, R-8a), with 10 further findings discovered
and fixed.

## Two places the backlog's own index is wrong

Recorded because closing from the index rather than the finding text would have
shipped the wrong fix:

| ID | Index says | The finding text says |
|---|---|---|
| UX-016 | "quality/limit counters absent from the list view" | there is **no way to filter «قيد المراجعة»** |
| UX-025 | narrowed to LOW because "the detail sheet shows it" | the detail sheet does **not** show it |

## Count

The backlog's own master index says "31 assigned, 31 recorded", but that index
predates UX-032…UX-037. The final line states **37**, and 37 distinct IDs are
present. **37 is authoritative.**
