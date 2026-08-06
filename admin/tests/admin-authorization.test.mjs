import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("admin allowlist is self-readable and never client-writable", () => {
  const migration = read("../supabase/migrations/0035_admin_authorization.sql");
  assert.match(migration, /enable row level security/i);
  assert.match(migration, /using \(auth\.uid\(\) = id\)/i);
  assert.match(migration, /revoke all on table public\.admin_users from public, anon, authenticated/i);
  assert.doesNotMatch(migration, /policy[\s\S]+for (insert|update|delete)/i);
});

test("middleware denies normal authenticated users using database membership", () => {
  const middleware = read("middleware.ts");
  assert.match(middleware, /from\("admin_users"\)/);
  assert.match(middleware, /if \(!isAdmin && !isNotAuthorized\)/);
  assert.match(middleware, /\/not-authorized/);
  assert.doesNotMatch(middleware, /cookies.*(isAdmin|role)|headers.*(isAdmin|role)/i);
});

test("all admin API handlers invoke the server authorization guard", () => {
  for (const path of [
    "app/api/admin-session/route.ts",
    "app/api/admin-data/route.ts",
    "app/api/announcements/route.ts",
    "app/api/campaigns/route.ts",
  ]) {
    const source = read(path);
    const handlers = [...source.matchAll(/export async function (GET|POST|PATCH|DELETE)[\s\S]*?(?=export async function|$)/g)];
    assert.ok(handlers.length > 0, `${path} should export handlers`);
    for (const handler of handlers) {
      assert.match(handler[0], /requireAdmin\(\)/, `${path} ${handler[1]} must require admin`);
    }
  }
});

// MALI-041 — a quote/whitespace-independent structural contract (was a brittle
// double-quote string match). It proves the parser-test privileged path (1) verifies
// authentication, (2) verifies the admin allowlist, (3) does BOTH before the first
// privileged read — and cannot trust a caller-supplied identity.
const _first = (source, regex) => {
  const m = regex.exec(source);
  return m ? m.index : -1;
};
const _reAuth = /auth\s*\.\s*getUser\s*\(/;
const _reAdmin = /\.\s*from\s*\(\s*['"]admin_users['"]\s*\)/;
const _reRead = /\.\s*from\s*\(\s*['"]sms_parsers['"]\s*\)/;

// Returns true only when auth → admin allowlist → first privileged read appear in
// that order. Quote/whitespace/format independent.
function enforcesAuthThenAdminThenRead(source) {
  const auth = _first(source, _reAuth);
  const admin = _first(source, _reAdmin);
  const read = _first(source, _reRead);
  if (auth < 0 || admin < 0 || read < 0) return false;
  return auth < admin && admin < read;
}

test("parser test verifies JWT and admin allowlist before privileged reads", () => {
  const source = read("../supabase/functions/parser-test/index.ts");
  assert.ok(
    enforcesAuthThenAdminThenRead(source),
    "auth.getUser → admin_users allowlist → sms_parsers read (in that order)",
  );
  // Never trusts a caller-supplied admin identity (no role/header/body admin claim).
  assert.doesNotMatch(
    source,
    /(isAdmin|is_admin|role)\s*[=:]\s*(req|request|body|headers|payload)/i,
  );
});

// Negative self-tests: the contract check MUST fail when the security property is
// broken — so a future regression cannot pass silently.
test("contract FAILS when the authentication check is removed", () => {
  const source = read("../supabase/functions/parser-test/index.ts").replace(
    _reAuth,
    "noAuth(",
  );
  assert.equal(enforcesAuthThenAdminThenRead(source), false);
});

test("contract FAILS when the admin allowlist check is removed", () => {
  const source = read("../supabase/functions/parser-test/index.ts").replace(
    _reAdmin,
    ".from('not_admin')",
  );
  assert.equal(enforcesAuthThenAdminThenRead(source), false);
});

test("contract FAILS when a privileged read occurs before the checks", () => {
  const bad =
    "await client.from('sms_parsers').select('*');\n" +
    "await client.auth.getUser(token);\n" +
    "await client.from('admin_users').select('id');";
  assert.equal(enforcesAuthThenAdminThenRead(bad), false);
});

// MALI-041 REGRESSION (the exact original failure mode) — the prior assertion matched
// a hard-coded double-quote literal `.from("admin_users")` and therefore reported a
// FALSE failure whenever the (correct) source used single quotes. This locks in
// quote-style invariance: a correctly-ordered path must pass in BOTH quote styles, and
// specifically the single-quote form that used to trip the old test must now pass.
test("MALI-041 regression: auth-order contract is quote-style invariant", () => {
  const withQuote = (q) =>
    [
      "const { data: { user } } = await client.auth.getUser(token);",
      `const { data: admin } = await client.from(${q}admin_users${q}).select(${q}id${q});`,
      `const { data: rows } = await client.from(${q}sms_parsers${q}).select(${q}*${q});`,
    ].join("\n");

  const singleQuoted = withQuote("'"); // the form the OLD double-quote test failed on
  const doubleQuoted = withQuote('"');

  assert.equal(
    enforcesAuthThenAdminThenRead(singleQuoted),
    true,
    "single-quote source must pass (this is the exact MALI-041 false-failure input)",
  );
  assert.equal(
    enforcesAuthThenAdminThenRead(doubleQuoted),
    true,
    "double-quote source must pass",
  );

  // And the invariance is real: swapping ' ↔ " on the whole source changes nothing.
  assert.equal(
    enforcesAuthThenAdminThenRead(singleQuoted),
    enforcesAuthThenAdminThenRead(doubleQuoted),
    "verdict must not depend on quote style",
  );

  // The live source (whatever quote style it actually uses today) also satisfies it —
  // so the regression is anchored to the real file, not only to synthetic fixtures.
  assert.equal(
    enforcesAuthThenAdminThenRead(
      read("../supabase/functions/parser-test/index.ts"),
    ),
    true,
    "the real parser-test source satisfies the quote-independent contract",
  );
});
