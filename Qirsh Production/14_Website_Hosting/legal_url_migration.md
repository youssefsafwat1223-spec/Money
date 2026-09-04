# Legal URL Migration — Workers → `qirsh.site`

**COMPLETED 2026-08-30.** The built-in default is now `https://qirsh.site`.
The Codemagic variable still needs updating — see step 4.
Kept as the record of what was done, and of how to roll back.

## State after migration

| | |
|---|---|
| Canonical legal host | `https://qirsh.site` |
| Rollback host | `https://qirsh-legal.albaraai-dev.workers.dev` — still live, do not delete |
| Built-in default (`legal_urls.dart`) | **`https://qirsh.site`** |
| Pinned tests | **`https://qirsh.site`** |
| Codemagic `LEGAL_BASE_URL` | still the Workers URL — **needs updating** (step 4) |

The Workers host **stays live throughout, and after.** It is the rollback, and
builds already in users' hands have its URL compiled in.

## One behaviour difference worth knowing

The two hosts canonicalise differently, and the new one is better:

| Request | Workers (now) | Nginx `try_files` (target) |
|---|---|---|
| `/privacy` | 307 → `/privacy/` → 200 | **200 directly** |
| `/privacy/` | 200 | 200 |

The app builds `<base>/privacy`, so on `qirsh.site` that becomes a single 200
with no redirect hop. Nothing in the app needs to change for this — it is a
property of the Nginx config in [`vps_and_nginx.md`](vps_and_nginx.md).

## Preconditions — all must hold before step 1

> **Note added 2026-09-04.** This checklist is entirely unticked while the header
> declares the migration COMPLETED. The migration *did* happen — `qirsh.site`
> serves `/privacy` and `/en/privacy` with 200 over valid TLS and is the built-in
> default in `legal_urls.dart`. The boxes were simply never filled in. Treat the
> header as authoritative and this list as a record of what should have been
> confirmed, not as evidence that it was not.

- [ ] `qirsh.site` deployed and serving from the VPS
- [ ] Valid TLS on `qirsh.site` (and `www`)
- [ ] `https://qirsh.site/privacy` → **200**, renders, mobile-readable
- [ ] `https://qirsh.site/terms` → **200**, renders, mobile-readable
- [ ] Content verified byte-identical in substance to `docs/legal/*.md`
- [ ] Business email still delivering (see [`dns_plan.md`](dns_plan.md))

Independently verified means: fetched over the public internet, not from the
build directory and not from localhost.

## Sequence

**1 — Verify the new host serves the documents.**

```bash
curl -sI https://qirsh.site/privacy | head -1     # HTTP/2 200
curl -sI https://qirsh.site/terms   | head -1     # HTTP/2 200
```

**2 — Change the built-in default.**
`app/lib/core/config/legal_urls.dart` → `_kLegalBaseUrl = 'https://qirsh.site'`
(no trailing slash — the paths are concatenated directly).

**3 — Update the pinned tests.**
`app/test/core/legal_urls_test.dart` names the host explicitly in two places, by
design, so a silent change fails the suite instead of shipping quietly. Update
both `liveHost` constants. Run:

```bash
cd app && flutter test test/core/legal_urls_test.dart
cd app && flutter test test/core/legal_urls_test.dart --dart-define=LEGAL_BASE_URL=https://qirsh.site
```

**4 — Update Codemagic `LEGAL_BASE_URL`** in the `supabase` group to
`https://qirsh.site`. Still required for production — the built-in default
protects users, the variable declares release intent.

**5 — Build and verify from an installed build.** Not from a browser. Open
Settings → الخصوصية والبيانات and tap both links. They must open `qirsh.site`.

**6 — Update the store listings.**
- App Store Connect → Privacy Policy URL → `https://qirsh.site/privacy`
- Play Console → Privacy Policy URL → `https://qirsh.site/privacy`

**7 — Update documentation.**
`04_Legal/domain_status.md`, `04_Legal/legal_release_checklist.md`,
`04_Legal/hosting_instructions.md`, the runbook, and the readiness dashboard.

**8 — Leave the Workers host running.** Do not delete it. Optionally redirect it
to `qirsh.site` once you are confident, but keep the name resolving: shipped
builds request it, and a store review may still reference it.

## Rollback

Any step before 6 rolls back by reverting steps 2–4 and rebuilding — the Workers
host never stopped serving, so there is no window where legal URLs are dead.

After step 6, rollback also means restoring the store URLs. Store review can take
days, so **verify thoroughly before step 6**; it is the point where rollback
stops being cheap.

## Why not do this now

`qirsh.site` does not exist yet as a served host. Repointing the app or a store
listing at a domain that does not yet serve the documents is the one sequencing
error here that is visible to users and to reviewers — a dead privacy URL is a
store rejection.
