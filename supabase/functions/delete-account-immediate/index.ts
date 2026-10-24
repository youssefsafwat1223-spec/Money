// delete-account-immediate - DRAFT, NOT DEPLOYED, NOT WIRED TO SUPABASE.
//
// Fails closed. The Apple gateway (challenge verification, code exchange and
// token revocation) and the token sealer (KMS-backed encryption) have no
// production implementation yet, so `config.apple_signing`, `token_encryption`
// and `intent_verification` report false and the coordinator answers
// not_configured before any side effect. Supplying those two collaborators is a
// named open item in supabase/drafts/account_deletion_fence/DECISIONS.md.
//
// The service-role client is created only from the platform-provided function
// environment at request time; nothing here is evaluated by tests.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { type AppleGateway, buildAccountDeletionCoordinator, type MaterialSealer } from '../_shared/account_deletion_adapter.ts';
import { createDeleteAccountHandler } from './handler.ts';

const unconfiguredApple: AppleGateway = {
  authorize: async () => ({ status: 'not_configured' }),
  revoke: async () => 'retryable',
};
const unconfiguredSealer: MaterialSealer = {
  seal: async () => {
    throw new Error('sealer_not_configured');
  },
  unseal: async () => {
    throw new Error('sealer_not_configured');
  },
};

let cached: ((req: Request) => Promise<Response>) | null = null;

function handler(): (req: Request) => Promise<Response> {
  if (cached) return cached;
  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const coordinator = buildAccountDeletionCoordinator({
    rpc: { rpc: (fn, args) => db.rpc(fn, args) as never },
    identity: {
      getUser: async (jwt) => {
        const { data, error } = await db.auth.getUser(jwt);
        return error || !data?.user ? null : { id: data.user.id };
      },
    },
    apple: unconfiguredApple,
    sealer: unconfiguredSealer,
    storage: db.storage as never,
    authAdmin: {
      deleteUser: async (uid) => {
        const { error } = await db.auth.admin.deleteUser(uid);
        return { error: error ? { status: error.status, code: error.code, message: error.message } : null };
      },
    },
    config: {
      database: url !== '' && serviceKey !== '',
      storage_admin: url !== '' && serviceKey !== '',
      auth_admin: url !== '' && serviceKey !== '',
      // No production implementation exists yet: keep these false.
      intent_verification: false,
      apple_signing: false,
      token_encryption: false,
    },
  });
  cached = createDeleteAccountHandler({ coordinator, workerId: `edge-${crypto.randomUUID()}` });
  return cached;
}

Deno.serve((req) => handler()(req));
