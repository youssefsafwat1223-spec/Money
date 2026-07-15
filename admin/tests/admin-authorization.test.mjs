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

test("parser test verifies JWT and admin allowlist before privileged reads", () => {
  const source = read("../supabase/functions/parser-test/index.ts");
  const authIndex = source.indexOf("client.auth.getUser(token)");
  const adminIndex = source.indexOf('.from("admin_users")');
  const parserIndex = source.indexOf('.from("sms_parsers")');
  assert.ok(authIndex >= 0 && adminIndex > authIndex && parserIndex > adminIndex);
});
