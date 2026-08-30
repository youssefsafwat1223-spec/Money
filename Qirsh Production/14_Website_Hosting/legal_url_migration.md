# Legal URL Migration — Workers → `qirsh.site`

**Not started. `LEGAL_BASE_URL` and the built-in default are unchanged.**

## Current state

| | |
|---|---|
| Live legal host | `https://qirsh-legal.albaraai-dev.workers.dev` |
| Status | approved **temporary** production host — live, HTTPS, production-safe |
| Built-in default (`legal_urls.dart`) | the Workers host |
| Codemagic `LEGAL_BASE_URL` | the Workers host — still required for production |
| Target | `https://qirsh.site` |

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
