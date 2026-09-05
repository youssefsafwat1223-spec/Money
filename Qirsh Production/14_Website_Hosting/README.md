# 14 — Website & Hosting

The public site at `qirsh.site` and the admin app at `admin.qirsh.site`.

**⚠️ THIS PARAGRAPH WAS STALE AND IS CORRECTED — 2026-09-04.**

**The public site IS deployed and live.** `qirsh.site` resolves to the Qirsh VPS
(`72.62.236.204`) and serves all eight routes over valid TLS with HSTS, from
`/var/www/qirsh-site` under Nginx. It has been live since approximately
2026-08-30. DNS exists; the apex `A` record is in place.

Deploy with the documented command in [`vps_and_nginx.md`](vps_and_nginx.md):
**`tools/deploy_site.sh`** — the canonical deploy. Do not hand-run rsync.

```bash
ADMOB_PUBLISHER_ID=pub-… python3 tools/build_site.py
tools/deploy_site.sh                 # add --preflight-only to check without deploying
```

It fails CLOSED before touching production: the tree must exist, all eight routes
and `app-ads.txt` must be present and non-empty, `app-ads.txt` must match
`google.com, pub-<16 digits>, DIRECT, f08c47fec0942fa0`, and it must be identical
to what is already live unless `--allow-app-ads-change` is passed. It then rsyncs,
fixes ownership, and re-verifies `app-ads.txt` over HTTP.

**Why:** the deploy used to be a raw `rsync -av --delete`, and `build_site.py`
emits `app-ads.txt` only when `ADMOB_PUBLISHER_ID` is set — so a rebuild without
that variable silently DELETED the live file while reporting success.

Last deploy: **2026-09-04, revision `f5cabf4d`** — the corrected legal copy.

*Original text, kept as the record of what this said:* "Phase 1 (local build) is
done. Nothing is deployed. No DNS record has been created. Hostinger has not been
contacted." That stopped being true when the VPS was provisioned and was never
updated — which is why a false claim sat live on the privacy policy for days
while the repository believed nothing was published at all.

| Document | Covers |
|---|---|
| [`admin_hosting.md`](admin_hosting.md) | what the admin app is, why it cannot be static, its auth boundary |
| [`vps_and_nginx.md`](vps_and_nginx.md) | VPS sizing, both Nginx server blocks, systemd unit, TLS, deploy |
| [`dns_plan.md`](dns_plan.md) | records to add, and the email records that must not be touched |
| [`legal_url_migration.md`](legal_url_migration.md) | moving the legal URLs off the Workers host, safely |

## Architecture

```
qirsh.site        ─▶ Nginx ─▶ /var/www/qirsh-site   static, generated
www.qirsh.site    ─▶ Nginx ─▶ 301 to qirsh.site
admin.qirsh.site  ─▶ Nginx ─▶ 127.0.0.1:3001        Next.js under systemd
```

## The public site

Built by **`tools/build_site.py`** into `build/site/` — **bilingual**, eight
routes, 13 files, 368 KB total, ~82 KB first load.

Arabic is the default and lives at the root, because the app is Arabic-first.
English lives under `/en/`. Every page carries `hreflang`, a canonical, and a
switcher in the header.

| Arabic (default) | English | Source |
|---|---|---|
| `/` | `/en/` | generated homepage |
| `/privacy` | `/en/privacy` | `docs/legal/PRIVACY_POLICY.md` |
| `/terms` | `/en/terms` | `docs/legal/TERMS.md` |
| `/support` | `/en/support` | generated |

**The legal documents stay English in both locales, deliberately.** `docs/legal/`
is the approved, reviewed text and a test asserts it matches what the code does.
Translating it would raise "which version governs?" — a legal question, not a
design one. The Arabic pages put the Arabic shell around the English document,
say so in a line above it, and mark the body `lang="en" dir="ltr"` so it reads
correctly inside an RTL page.

Copy lives in `tools/site_content.py`, separated from markup so wording can be
reviewed without reading HTML.

The brand typeface is **IBM Plex Sans Arabic** — the app's own family — subset to
Arabic + Latin and converted to woff2: **66 KB for both weights instead of
480 KB**. That is what made using the real face affordable rather than falling
back to a system stack. See `tools/site_assets/README.md`.

```bash
python3 tools/build_site.py
```

Standard library only — no npm, no framework, no build toolchain on the server.
It **imports** the Markdown renderer from `build_legal_site.py` rather than
copying it, so the legally-critical path has one implementation and cannot drift
between the two sites.

**Light mode only.** `tools/site_style.css` contains no `prefers-color-scheme`
rule and there is no toggle. Verified by rendering every page with
`prefers-color-scheme: dark` forced: the background stays `#F4F6FB`.

**No admin link appears on any public page.** Verified: zero occurrences of the
string anywhere in `build/site/`. That is hygiene, not security — see
`admin_hosting.md` on why the real boundary is the `admin_users` gate.

## Two things that will bite if skipped

**The business email lives in the same DNS zone.** Adding `A` records is safe;
deleting or replacing an unfamiliar row is not. Export the zone first, and send a
test email to `business@qirsh.site` after the change. DNS resolving for the
website tells you nothing about whether mail still routes.

**`next build` is the memory peak, not serving.** On 2 GB with no swap it gets
OOM-killed, and the failure looks like a code error rather than a sizing problem.
KVM 2, or build off the box.
