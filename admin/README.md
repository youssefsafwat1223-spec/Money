# Qirsh Admin — runbook

Next.js 14 dashboard for the Qirsh catalog, growth and system settings.
Arabic-first, RTL, on port `3001`.

## Running it

| Command | What it does | Supabase target |
|---|---|---|
| `npm run dev:local` | **Local development.** Reads `.env.development.local`. | Your local Supabase stack |
| `npm run dev` | Development with whatever env is configured. | Refuses known deployed projects — see below |
| `npm run build` && `npm start` | Production build / serve. Unchanged by the guard. | `.env.local` |

### Local development (recommended)

```bash
# 1. Start your local Supabase stack, then read its config:
supabase status

# 2. Create the local env file from the template and fill in those values:
cp admin/.env.local.example admin/.env.development.local

# 3. Run:
cd admin && npm run dev:local
```

`.env.development.local` is git-ignored, and in development Next.js loads it
**ahead of** `.env.local` — so your deployed configuration is shadowed for local
runs without being edited or moved.

### The local-run guard

`admin/.env.local` legitimately holds the deployed project's configuration, so a
plain `npm run dev` would otherwise point your laptop at a real backend.

When `NODE_ENV=development`, the Admin **fails closed** before serving anything
if `NEXT_PUBLIC_SUPABASE_URL` names a known deployed project (production,
evidence staging, validation staging). The check runs in the middleware — which
sees every page and every `/api` request — and again in the server client
factories that sit in front of every mutation, so no request reaches a handler.

`next build` and `next start` run with `NODE_ENV=production`, where the guard is
a no-op. **Production build and runtime behaviour are unchanged.**

Implementation: `lib/env-guard.ts`.

### Intentionally targeting a remote project

Sometimes you really do need to reproduce something against a deployed project.
The opt-in is explicit and must **name the exact project ref**, so an opt-in left
over from a staging session can never silently authorise production:

```bash
ADMIN_ALLOW_REMOTE_SUPABASE=<project-ref> npm run dev
```

The run prints a warning naming the project it is talking to. Prefer read-only
work; every write goes to that real project.

## Checks

```bash
npm run lint
npm run test:auth     # route protection, admin authorization, idempotency, coupons
npm run build
```

`test:auth` includes `Z2`, which greps the **built** client bundle for
service-role material — run `npm run build` first or it is skipped.
