/**
 * Admin local-run safety.
 *
 * `admin/.env.local` legitimately holds the deployed project's configuration, so
 * the default `npm run dev` would otherwise point a developer's laptop straight
 * at a real backend. This guard makes that combination fail closed instead.
 *
 * SCOPE — development only. Every export returns immediately unless
 * `NODE_ENV === "development"`, so `next build` and `next start` (both of which
 * run with `NODE_ENV=production`) behave exactly as they did before. Nothing
 * here changes deployment behaviour, and no local URL or credential is baked
 * into this file.
 *
 * The guard is deliberately SERVER-SIDE only. It runs in the middleware — which
 * sees every page and every `/api` request — and again inside the server client
 * factories that sit directly in front of every mutation. A request is refused
 * before any handler runs, so the browser never reaches a state where it could
 * issue one. (It is also why the opt-in below can be a private env var: it never
 * needs to be readable from the client bundle.)
 */

/** Remote Supabase projects that must never be reached from a dev laptop. */
const REMOTE_PROJECT_REFS: Readonly<Record<string, string>> = {
  vrombzdgwqjjiijbidqb: "production",
  dpdukyozedajelflkeix: "evidence staging",
  bdhqjijscwdzqwqanygv: "validation staging",
};

/**
 * Named opt-in. The value must be the EXACT project ref being targeted, so an
 * opt-in left over from a staging session can never silently authorise
 * production.
 */
const OPT_IN_VAR = "ADMIN_ALLOW_REMOTE_SUPABASE";

/** Returns the known remote project ref contained in `url`, or null. */
export function findRemoteProjectRef(url: string | undefined | null): string | null {
  if (!url) return null;
  for (const ref of Object.keys(REMOTE_PROJECT_REFS)) {
    if (url.includes(ref)) return ref;
  }
  return null;
}

export function describeRemoteProjectRef(ref: string): string {
  return REMOTE_PROJECT_REFS[ref] ?? "a known remote project";
}

function buildMessage(ref: string, url: string): string {
  const label = describeRemoteProjectRef(ref);
  return [
    "",
    "  ┌───────────────────────────────────────────────────────────────────┐",
    "  │  Qirsh Admin — refusing to start against a remote project         │",
    "  └───────────────────────────────────────────────────────────────────┘",
    "",
    `  NEXT_PUBLIC_SUPABASE_URL points at ${label.toUpperCase()} (${ref}).`,
    `    ${url}`,
    "",
    "  You are running in development. Local development must not read from or",
    "  write to a deployed project.",
    "",
    "  To develop locally (recommended):",
    "    1. Start the local Supabase stack, then run `supabase status` to read",
    "       its API URL and anon key.",
    "    2. Copy admin/.env.local.example to admin/.env.development.local and",
    "       fill in those local values. That file is git-ignored and takes",
    "       precedence over .env.local in development.",
    "    3. npm run dev:local",
    "",
    "  If you genuinely need to point local development at this remote project,",
    "  acknowledge it explicitly by naming the exact ref:",
    `    ${OPT_IN_VAR}=${ref} npm run dev`,
    "",
  ].join("\n");
}

/**
 * Fails closed when development is configured against a known remote project.
 * No-op in production, and no-op for any URL that is not a known remote ref
 * (so a self-hosted or local Supabase is unaffected).
 */
export function assertSafeSupabaseTarget(): void {
  if (process.env.NODE_ENV !== "development") return;

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const ref = findRemoteProjectRef(url);
  if (!ref) return;

  if (process.env[OPT_IN_VAR] === ref) {
    warnOptIn(ref);
    return;
  }

  throw new Error(buildMessage(ref, url ?? ""));
}

let warned = false;
function warnOptIn(ref: string): void {
  if (warned) return;
  warned = true;
  console.warn(
    `\n  ⚠  Qirsh Admin: development is explicitly pointed at ${describeRemoteProjectRef(ref)} ` +
      `(${ref}) via ${OPT_IN_VAR}.\n     Every read and write goes to that project.\n`,
  );
}
