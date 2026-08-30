# Admin Application — Hosting Analysis

Read-only inspection of `admin/` as it stands. No file in `admin/` was modified.

## What it actually is

| Property | Value |
|---|---|
| Framework | **Next.js 14.2.29** (App Router) |
| Runtime | **Node.js** — server required |
| Language | TypeScript 5.5, React 18.3 |
| UI | Tailwind 3.4, lucide-react, recharts |
| Data | `@supabase/supabase-js` + `@supabase/ssr` |
| Build | `npm run build` → `next build` |
| Start | `npm start` → `next start --port 3001` |
| Output | `.next/` (server build — **not** a static export) |

## Can it run as a static site? **No.**

Three independent reasons, each sufficient on its own:

1. **21 API routes** under `app/api/`. These execute server-side.
2. **`middleware.ts`** runs on every request — it is the authentication and
   authorisation gate (see below). A static host has no middleware.
3. **`SUPABASE_SERVICE_ROLE_KEY`** is read server-side. That key must never
   reach a browser, so the code that uses it can only run on a server.

`next.config.mjs` sets no `output: 'export'`, which is consistent: this was
built as a server application.

So `admin.qirsh.site` needs a **persistent Node process**, reverse-proxied by
Nginx. It cannot be a folder of files like the public site.

## Authentication boundary

`middleware.ts` enforces two checks in order, before any admin page renders:

1. **Session** — `supabase.auth.getUser()`. No user ⇒ redirect to `/login`.
2. **Authorisation** — the user's id must exist in the **`admin_users`** table.
   Not an env-var allowlist, not a hardcoded email: a row in the production
   database, protected by RLS.

This is a real boundary and it does not depend on the URL being unknown. Worth
stating plainly because the brief raises it: **`admin.qirsh.site` being
undiscoverable is not a security control.** It is only a convenience. The gate
above is the control, and it would hold even if the hostname were printed on the
homepage.

`admin/tests/*.test.mjs` (`npm run test:auth`) covers this boundary.

## Environment variables

| Variable | Exposure | Notes |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | ships to browser | public by design |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | ships to browser | public by design |
| `SUPABASE_SERVICE_ROLE_KEY` | **server only** | full database access — never in `NEXT_PUBLIC_*`, never in the image, never in git |
| `PORT` | server | defaults to 3001 |
| `NODE_ENV` | server | `production` |

Node version is **not pinned** in `package.json` (`engines` absent). Next 14.2
requires Node ≥ 18.17. Pin the VPS to **Node 20 LTS** and record it, so a future
`apt upgrade` cannot silently move the runtime under a working deployment.

`lib/env-guard.ts` refuses to serve if a *development* server is pointed at a
deployed project. It is a no-op under `NODE_ENV=production`, so it protects
local work, not production.

## Is `admin.qirsh.site` suitable?

**Yes.** A separate subdomain is the right shape here, for reasons that are
structural rather than cosmetic:

- **Separate origin.** Cookies, storage and any XSS are scoped to
  `admin.qirsh.site` and cannot reach the public site, and vice versa.
- **Separate Nginx server block**, so admin-only rules — `noindex`, IP
  allowlisting, rate limits, stricter headers — apply to the admin and not to
  the marketing pages.
- **Separate failure domain.** The public site is static files; if the Node
  process is down, `qirsh.site` is unaffected.
- **Separate TLS certificate**, issued and renewed independently.

A path prefix (`qirsh.site/admin`) would share the origin with the public site
and put an authenticated surface behind the same cookie scope as a page anyone
can visit. The subdomain is meaningfully safer.

## What the admin host must have before it goes live

- [ ] HTTPS with a valid certificate, HTTP redirected to HTTPS
- [ ] `X-Robots-Tag: noindex, nofollow` **and** a `robots.txt` disallow
- [ ] Real authentication — already present via Supabase session
- [ ] Real authorisation — already present via `admin_users`
- [ ] `Secure`, `HttpOnly`, `SameSite` cookies (Supabase SSR sets these; verify
      `Secure` actually applies, which needs the app to know it is behind TLS —
      pass `X-Forwarded-Proto`)
- [ ] `SUPABASE_SERVICE_ROLE_KEY` in a root-owned `0600` env file read by
      systemd, **never** in the repository or the shell history
- [ ] Rate limiting on `/login` and `/api/` — see
      [`vps_and_nginx.md`](vps_and_nginx.md)
- [ ] Security headers: HSTS, `X-Content-Type-Options`, `X-Frame-Options: DENY`,
      a Referrer-Policy

## Not done, and deliberately

The admin application was **not redesigned or modified**. This is analysis only,
as scoped. The one change it will eventually need for production hosting is
operational rather than visual: reading configuration from the environment the
systemd unit provides, which it already does.
