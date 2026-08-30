# 14 — Website & Hosting

The public site at `qirsh.site` and the admin app at `admin.qirsh.site`.

**Phase 1 (local build) is done. Nothing is deployed. No DNS record has been
created. Hostinger has not been contacted.**

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
