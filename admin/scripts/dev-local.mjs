#!/usr/bin/env node
/**
 * `npm run dev:local` — start the Admin against a LOCAL Supabase stack.
 *
 * This script deliberately contains no URL and no key. It only checks that the
 * developer has supplied local configuration in `admin/.env.development.local`
 * (git-ignored) and then hands over to `next dev`.
 *
 * Next.js loads `.env.development.local` ahead of `.env.local` in development,
 * so the deployed configuration in `.env.local` is shadowed for local runs
 * without being edited or moved.
 */
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const ENV_FILE = fileURLToPath(new URL("../.env.development.local", import.meta.url));
const EXAMPLE = fileURLToPath(new URL("../.env.local.example", import.meta.url));

// Kept in sync with lib/env-guard.ts — this is the early, friendlier failure.
const REMOTE_PROJECT_REFS = {
  vrombzdgwqjjiijbidqb: "production",
  dpdukyozedajelflkeix: "evidence staging",
  bdhqjijscwdzqwqanygv: "validation staging",
};

function fail(lines) {
  console.error(`\n${lines.join("\n")}\n`);
  process.exit(1);
}

if (!existsSync(ENV_FILE)) {
  fail([
    "  Qirsh Admin — local development is not configured yet.",
    "",
    "  Missing: admin/.env.development.local",
    "",
    "  1. Start your local Supabase stack, then run `supabase status` to read",
    "     its API URL and anon key.",
    `  2. Copy the template:  cp ${EXAMPLE.replace(/.*\/admin\//, "admin/")} admin/.env.development.local`,
    "  3. Fill in the local API URL, anon key and service-role key.",
    "  4. Re-run: npm run dev:local",
    "",
    "  The file is git-ignored and takes precedence over .env.local in",
    "  development, so your deployed configuration stays untouched.",
  ]);
}

const contents = readFileSync(ENV_FILE, "utf8");
for (const [ref, label] of Object.entries(REMOTE_PROJECT_REFS)) {
  if (contents.includes(ref)) {
    fail([
      `  Qirsh Admin — admin/.env.development.local points at ${label.toUpperCase()} (${ref}).`,
      "",
      "  `dev:local` is for a local Supabase stack only. Replace those values",
      "  with the output of `supabase status`.",
    ]);
  }
}

const port = process.env.PORT ?? "3001";
console.log(
  `  Qirsh Admin — starting on port ${port} with admin/.env.development.local (local stack).\n`,
);

const child = spawn("npx", ["next", "dev", "--port", port], {
  cwd: fileURLToPath(new URL("..", import.meta.url)),
  stdio: "inherit",
  env: process.env,
});
child.on("exit", (code) => process.exit(code ?? 0));
