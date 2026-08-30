# Legal Domain Status

Authoritative statement of which host serves the legal documents, what its
status is, and what remains. Referenced by the runbook, the legal release
checklist and the readiness dashboard — update it here, not in copies.

## Current host — approved, temporary

```
https://qirsh-legal.albaraai-dev.workers.dev
```

| Property | Status |
|---|---|
| Live | **yes** — `/` 200, `/privacy` and `/terms` 200 via a 307 to the trailing-slash form |
| HTTPS | **yes** — valid certificate, HTTP/2 |
| Production-safe | **yes** |
| Approved for current releases | **yes** — including App Store and Play submission |
| Permanent | **no** — see below |

This is a **deliberate, approved production choice**, not a compromise made in
the dark. Release preparation should not idle waiting on a domain purchase when
a healthy HTTPS host already serves the correct documents.

### What it must NOT be called

Not a **placeholder**. Not **broken**. Not **staging**. Not
**development-only**. Not a **release blocker**. It is the real host currently
serving real users, and it is fit for store review.

The word "placeholder" has specific history here and must not leak back: the
built-in default was once `mali.youssefsafwat.com`, which did not resolve. That
was a genuine placeholder. This is not the same thing, and conflating them would
reintroduce a blocker that no longer exists.

## Final custom Qirsh domain — not yet

- **Not purchased. Not configured. Not named.** No domain is reserved or
  implied anywhere in this repository, and none should be invented before it is
  actually bought.
- It is a **future branding and infrastructure task**, not a release gate.
- **It does not block the current release** for as long as the approved
  temporary host stays healthy.

The only thing that would turn this into a blocker is the temporary host
becoming unhealthy — so the check that matters is uptime of the current host,
not the acquisition of the future one.

## Configuration as it stands — unchanged

Both point at the temporary host, and neither changes until the migration:

| Where | Value |
|---|---|
| Built-in fallback, `app/lib/core/config/legal_urls.dart` | `https://qirsh-legal.albaraai-dev.workers.dev` |
| Codemagic `LEGAL_BASE_URL`, `supabase` variable group | `https://qirsh-legal.albaraai-dev.workers.dev` |

The built-in default protects **users** if the variable is absent; the Codemagic
variable declares **release intent**. Both are required — see
[`legal_release_checklist.md`](legal_release_checklist.md).

---

## FUTURE TASK — Migrate legal hosting to the final Qirsh custom domain

**Status:** `[ ]` not started · **Blocks release:** **NO** · **Owner:** Youssef
(domain + stores) with Claude (source, docs) · **Trigger:** the final Qirsh
domain has been purchased and its DNS is under our control.

Ordered, because several steps invalidate each other if run out of sequence —
the URL must serve before anything is pointed at it, and the stores must be
updated before old builds age out.

1. **Deploy or attach the legal site to the final HTTPS custom domain.**
   Rebuild with `python3 tools/build_legal_site.py`; the output is
   host-independent, so no source change is needed to publish it.
2. **Verify `/privacy` and `/terms` on the new domain** — 200 (directly or via
   the canonical trailing-slash redirect), valid HTTPS, both pages rendering on
   mobile.
3. **Update the built-in legal base URL** in
   `app/lib/core/config/legal_urls.dart`, and the pinned expectations in
   `app/test/core/legal_urls_test.dart`. Both name the host explicitly, by
   design, so a silent change fails the test rather than shipping quietly.
4. **Update Codemagic `LEGAL_BASE_URL`** in the `supabase` variable group.
5. **Update the App Store Connect Privacy Policy URL.**
6. **Update the Google Play Console Privacy Policy URL.**
7. **Verify the links from installed iOS and Android release builds** — not
   from a browser. The point is to prove the define reached the binary.
8. **Update release and legal documentation** — this file, the runbook,
   `legal_release_checklist.md`, `hosting_instructions.md`, and the readiness
   dashboard.
9. **Preserve redirects if appropriate.** If the Workers host stays reachable,
   redirect it to the new domain rather than removing it. Builds already in
   users' hands carry the old URL compiled in and will keep requesting it; a
   store listing may also still reference it during review.

**Do not start steps 3–6 until step 2 passes.** Repointing the app or a store
listing at a domain that does not yet serve the documents is the one sequencing
mistake here that is visible to users and to reviewers.
