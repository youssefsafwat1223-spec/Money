// delete-account-immediate - DRAFT, NOT DEPLOYED, NOT WIRED TO SUPABASE.
//
// Fails closed unless every secret is present and well-formed at cold start:
// APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_CLIENT_ID, APPLE_PRIVATE_KEY_P8 and
// ACCOUNT_DELETION_SEALER_KEY (AES-256-GCM, base64 of 32 bytes). Until then
// `config.apple_signing`, `token_encryption` and `intent_verification` report
// false and the coordinator answers not_configured before any side effect, and
// the challenge route answers 503 not_configured.
//
// The service-role client is created only from the platform-provided function
// environment at request time; nothing here is evaluated by tests.

import { createDeleteAccountHandler } from './handler.ts';
import { buildDeletionRuntime } from '../_shared/account_deletion_runtime.ts';

let cached: Promise<(req: Request) => Promise<Response>> | null = null;

async function build(): Promise<(req: Request) => Promise<Response>> {
  const { coordinator, challenge } = await buildDeletionRuntime();
  return createDeleteAccountHandler({ coordinator, workerId: `edge-${crypto.randomUUID()}`, challenge });
}

function handler(): Promise<(req: Request) => Promise<Response>> {
  cached ??= build().catch((e) => {
    cached = null;
    throw e;
  });
  return cached;
}

Deno.serve(async (req) => (await handler())(req));
