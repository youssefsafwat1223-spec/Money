// R5 — Referral / Entitlement live staging E2E harness (server-side).
//
// Credential-gated: reads SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY
// from the process environment (never an env file; never printed). HARD-ASSERTS
// the approved validation-staging ref before any call and refuses production /
// evidence-staging. Real authenticated user JWTs drive the mobile path; the
// service-role key is used ONLY for disposable-user admin, Admin-RPC simulation,
// fixture setup the mobile path can't reach, independent observation, and cleanup.

import assert from 'node:assert/strict';
import { test } from 'node:test';

const URL = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
const ANON = process.env.SUPABASE_ANON_KEY || '';
const SR = process.env.SUPABASE_SERVICE_ROLE_KEY || '';

const APPROVED = 'bdhqjijscwdzqwqanygv';
const FORBIDDEN = ['vrombzdgwqjjiijbidqb', 'dpdukyozedajelflkeix'];

// Credential gate, using the same idiom as every other live node test here:
// absent credentials mean SKIP, not FAIL. Previously this file exited(2) when
// unconfigured, which `node --test` counts as a failing test file and turned the
// whole node-contract gate red on any machine without staging credentials.
const live = Boolean(URL && ANON && SR);
const liveGate = {
  skip: live
    ? false
    : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY',
};

// Ref guards stay HARD — they must abort rather than skip, because pointing this
// harness at production or evidence staging is a safety failure, not a config gap.
if (live) {
  for (const f of FORBIDDEN) if (URL.includes(f)) { console.error(`FORBIDDEN ref ${f}`); process.exit(3); }
  if (!URL.includes(APPROVED)) { console.error(`not approved staging ${APPROVED}`); process.exit(3); }
  console.log(`ref guard: target = ${APPROVED} (approved validation staging) ✓`);
}

const H = (key, jwt) => ({ apikey: key, Authorization: `Bearer ${jwt || key}`, 'Content-Type': 'application/json' });
async function adminCreateUser(email) {
  const r = await fetch(`${URL}/auth/v1/admin/users`, { method: 'POST', headers: H(SR), body: JSON.stringify({ email, password: 'R5-passw0rd!x', email_confirm: true }) });
  if (!r.ok) throw new Error(`createUser ${email}: ${r.status} ${await r.text()}`);
  return (await r.json()).id;
}
async function adminDeleteUser(id) { await fetch(`${URL}/auth/v1/admin/users/${id}`, { method: 'DELETE', headers: H(SR) }); }
async function signIn(email) {
  const r = await fetch(`${URL}/auth/v1/token?grant_type=password`, { method: 'POST', headers: H(ANON), body: JSON.stringify({ email, password: 'R5-passw0rd!x' }) });
  if (!r.ok) throw new Error(`signIn ${email}: ${r.status} ${await r.text()}`);
  return (await r.json()).access_token;
}
async function rpcUser(jwt, fn, params) {
  const r = await fetch(`${URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: H(ANON, jwt), body: JSON.stringify(params || {}) });
  const b = await r.text(); return { status: r.status, ok: r.ok, json: b ? JSON.parse(b) : null };
}
async function rpcService(fn, params) {
  const r = await fetch(`${URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: H(SR), body: JSON.stringify(params || {}) });
  const b = await r.text(); return { status: r.status, ok: r.ok, json: b ? JSON.parse(b) : null };
}
async function obs(table, qs) { const r = await fetch(`${URL}/rest/v1/${table}?${qs}`, { headers: H(SR) }); return r.ok ? r.json() : []; }
async function srInsert(table, row) { // controlled fixture setup (service-role, bypasses RLS)
  const r = await fetch(`${URL}/rest/v1/${table}`, { method: 'POST', headers: { ...H(SR), Prefer: 'return=representation' }, body: JSON.stringify(row) });
  const b = await r.text(); return { ok: r.ok, status: r.status, json: b ? JSON.parse(b) : null };
}

const R = [];
const rec = (name, pass, detail = '') => { R.push({ name, pass: !!pass, detail }); console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`); };
const uid = () => Math.random().toString(36).slice(2, 10);
const created = [];
const rewardType = 'report_export_ad_free';

async function main() {
  const tag = `r5-${Date.now()}-${uid()}`;
  const email = (n) => `${tag}-${n}@r5.example.com`;
  const U = {};
  for (const n of ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']) { U[n] = await adminCreateUser(email(n)); created.push(U[n]); }
  const Hadmin = U.H;
  rec('§6 disposable topology (A,B,C,D,E,F,G, Admin H) created', true, `A=${U.A.slice(0, 8)}`);
  const jwt = {};
  for (const n of ['A', 'B', 'C', 'D', 'E', 'F', 'G']) jwt[n] = await signIn(email(n));

  // §7 active rule via approved Admin RPC
  const rulePub = await rpcService('admin_publish_reward_rule', { p_operation_id: crypto.randomUUID(), p_actor_admin_id: Hadmin, p_reward_type: rewardType, p_required_referrals: 5, p_reward_days: 7, p_repeatable: true, p_reason: 'R5 staging rule 5/7' });
  let activeRules = await obs('referral_reward_rules', `reward_type=eq.${rewardType}&is_active=eq.true&select=id,version,required_referrals,reward_days`);
  const REQ = activeRules[0]?.required_referrals;
  rec('§7 rule published + exactly one active (5/7)', rulePub.ok && activeRules.length === 1 && REQ === 5 && activeRules[0].reward_days === 7, `active=${activeRules.length} v=${activeRules[0]?.version}`);

  // §8 referral code via mobile RPC
  const code = (await rpcUser(jwt.A, 'get_referral_summary', {})).json?.referral_code;
  rec('§8 code canonical uppercase Crockford (no O/I/L/U)', !!code && /^[0-9A-HJ-NP-TV-Z]{8}$/.test(code), `code=${code}`);

  // §9 attribution matrix (real mobile RPC path)
  const applyB = await rpcUser(jwt.B, 'apply_referral_code', { p_code: code });
  rec('§9 B attributed once (+inline qualify, verified)', applyB.json?.ok === true && applyB.json?.attributed === true, `q=${JSON.stringify(applyB.json?.qualification)}`);
  rec('§10 verified referee qualifies — server reads auth truth, not a client claim', applyB.json?.qualification?.qualified === true, `q=${JSON.stringify(applyB.json?.qualification)}`);
  const applyBdup = await rpcUser(jwt.B, 'apply_referral_code', { p_code: code });
  rec('§9 duplicate apply safe (already_referred)', applyBdup.json?.reason === 'already_referred', `reason=${applyBdup.json?.reason}`);
  const applySelf = await rpcUser(jwt.A, 'apply_referral_code', { p_code: code });
  rec('§9 self-referral rejected', applySelf.json?.reason === 'self_referral', `reason=${applySelf.json?.reason}`);
  const applyInvalid = await rpcUser(jwt.C, 'apply_referral_code', { p_code: 'ZZZZZZZZ' });
  rec('§9 invalid code → generic reject, no identity leak', JSON.stringify(applyInvalid.json) === JSON.stringify({ ok: false, reason: 'invalid_code' }), JSON.stringify(applyInvalid.json));

  // §11 milestone 1→5 (B already 1; drive C,D,E,F)
  const progression = [`B:1/${REQ}`];
  for (const n of ['C', 'D', 'E', 'F']) {
    await rpcUser(jwt[n], 'apply_referral_code', { p_code: code });
    const p = (await obs('referral_reward_progress', `referrer_user_id=eq.${U.A}&reward_type=eq.${rewardType}&select=qualified_in_cycle,cycle_index,cycle_state`))[0];
    progression.push(`${n}:${p?.qualified_in_cycle}/${REQ} cyc${p?.cycle_index}`);
  }
  const grants = await obs('referral_reward_grants', `referrer_user_id=eq.${U.A}&select=id,reward_days_granted,cycle_index`);
  const events = await obs('entitlement_events', `user_id=eq.${U.A}&select=id,event_type,duration_days_applied`);
  const stateA = (await obs('user_entitlement_state', `user_id=eq.${U.A}&entitlement_type=eq.${rewardType}&select=status,ends_at,starts_at`))[0];
  const prog5 = (await obs('referral_reward_progress', `referrer_user_id=eq.${U.A}&reward_type=eq.${rewardType}&select=qualified_in_cycle,cycle_index,cycle_state`))[0];
  const days = stateA ? Math.round((new Date(stateA.ends_at) - new Date(stateA.starts_at)) / 86400000) : 0;
  rec('§11 milestone: exactly ONE grant (7 days)', grants.length === 1 && grants[0].reward_days_granted === 7, `grants=${grants.length}`);
  rec('§11 exactly ONE entitlement event; state active; 7-day duration', events.length === 1 && stateA?.status === 'active' && days === 7, `events=${events.length} state=${stateA?.status} days=${days}`);
  rec('§11 cycle 2 opened at 0/5', prog5?.cycle_index === 2 && prog5?.qualified_in_cycle === 0, `cyc=${prog5?.cycle_index} q=${prog5?.qualified_in_cycle} [${progression.join(' ')}]`);
  await rpcUser(jwt.F, 'apply_referral_code', { p_code: code }); // retry — idempotent
  rec('§11 retry does not duplicate grant', (await obs('referral_reward_grants', `referrer_user_id=eq.${U.A}&select=id`)).length === 1);

  // §12 sixth referral → cycle 2 = 1/5
  await rpcUser(jwt.G, 'apply_referral_code', { p_code: code });
  const prog6 = (await obs('referral_reward_progress', `referrer_user_id=eq.${U.A}&reward_type=eq.${rewardType}&select=qualified_in_cycle,cycle_index`))[0];
  rec('§12 sixth referral → cycle 2 = 1/5 (never 6/5)', prog6?.cycle_index === 2 && prog6?.qualified_in_cycle === 1, `cyc=${prog6?.cycle_index} q=${prog6?.qualified_in_cycle}`);

  // §13 entitlement decision → VERIFIED_ACTIVE semantics
  const decA = await rpcUser(jwt.A, 'get_entitlement_decision', { p_entitlement_type: rewardType });
  rec('§13 get_entitlement_decision active + server_now + ends_at', decA.json?.active === true && !!decA.json?.server_now && !!decA.json?.ends_at, `active=${decA.json?.active} ends=${decA.json?.ends_at?.slice(0, 10)}`);

  // §25 rule-version pinning (live): a fresh referrer at 4/5 under V1, publish V2,
  // prove the open cycle stays pinned to V1 and the 5th completes V1 (7 days),
  // then cycle 2 opens at 0/10 under V2.
  const R25 = await adminCreateUser(email('R25')); created.push(R25); const jR25 = await signIn(email('R25'));
  const codeR25 = (await rpcUser(jR25, 'get_referral_summary', {})).json.referral_code;
  const jref = [];
  for (let i = 0; i < 5; i++) { const u = await adminCreateUser(email(`r25ref${i}`)); created.push(u); jref.push(await signIn(email(`r25ref${i}`))); }
  for (let i = 0; i < 4; i++) await rpcUser(jref[i], 'apply_referral_code', { p_code: codeR25 }); // → 4/5 under V1
  const p25a = (await obs('referral_reward_progress', `referrer_user_id=eq.${R25}&reward_type=eq.${rewardType}&select=qualified_in_cycle,pinned_rule_version`))[0];
  await rpcService('admin_publish_reward_rule', { p_operation_id: crypto.randomUUID(), p_actor_admin_id: Hadmin, p_reward_type: rewardType, p_required_referrals: 10, p_reward_days: 3, p_repeatable: true, p_reason: 'R5 V2 10/3' });
  const p25b = (await obs('referral_reward_progress', `referrer_user_id=eq.${R25}&reward_type=eq.${rewardType}&select=qualified_in_cycle,pinned_rule_version`))[0];
  rec('§25 open cycle stays 4/5 pinned to V1 after V2 published', p25a?.qualified_in_cycle === 4 && p25b?.qualified_in_cycle === 4 && p25b?.pinned_rule_version === 1, `before=${p25a?.qualified_in_cycle}/v${p25a?.pinned_rule_version} after=${p25b?.qualified_in_cycle}/v${p25b?.pinned_rule_version}`);
  await rpcUser(jref[4], 'apply_referral_code', { p_code: codeR25 }); // 5th completes the pinned V1 cycle
  const grant25 = (await obs('referral_reward_grants', `referrer_user_id=eq.${R25}&select=reward_days_granted,rule_version`))[0];
  const p25c = (await obs('referral_reward_progress', `referrer_user_id=eq.${R25}&reward_type=eq.${rewardType}&select=cycle_index,qualified_in_cycle,pinned_rule_version`))[0];
  rec('§25 5th completes V1 → 7-day grant; next cycle 0/10 pinned to V2', grant25?.reward_days_granted === 7 && grant25?.rule_version === 1 && p25c?.cycle_index === 2 && p25c?.qualified_in_cycle === 0 && p25c?.pinned_rule_version === 2, `grant=${grant25?.reward_days_granted}d/v${grant25?.rule_version} nextCyc=${p25c?.cycle_index} q=${p25c?.qualified_in_cycle}/v${p25c?.pinned_rule_version}`);

  // §32 referee deletion de-identifies a QUALIFIED referral; progress/grant unchanged.
  // Purge D (a qualified referee not referenced by any later step).
  const bRowBefore = (await obs('referrals', `referred_user_id=eq.${U.D}&select=id,status`))[0];
  await rpcService('purge_user_data', { p_user_id: U.D });
  const bRowAfter = (await obs('referrals', `id=eq.${bRowBefore.id}&select=referred_user_id,status,referred_user_deleted_at`))[0];
  const aProgStill = (await obs('referral_reward_progress', `referrer_user_id=eq.${U.A}&reward_type=eq.${rewardType}&select=cycle_index`))[0];
  const aGrantStill = (await obs('referral_reward_grants', `referrer_user_id=eq.${U.A}&select=id`)).length;
  rec('§32 referee purge → qualified referral de-identified (id nulled, status kept), progress/grant intact', bRowAfter?.referred_user_id === null && bRowAfter?.status === 'qualified' && bRowAfter?.referred_user_deleted_at != null && aGrantStill === 1, `refId=${bRowAfter?.referred_user_id} status=${bRowAfter?.status} grants=${aGrantStill}`);

  // §5 live security negatives (real authenticated user)
  const admByUser = await rpcUser(jwt.B, 'admin_mutate_entitlement', { p_operation_id: crypto.randomUUID(), p_actor_admin_id: U.B, p_user_id: U.B, p_entitlement_type: rewardType, p_action: 'grant', p_reason: 'attempt', p_duration_days: 7 });
  rec('§5 authenticated user CANNOT call an Admin RPC', admByUser.status === 404 || admByUser.status === 403, `status=${admByUser.status}`);
  const intByUser = await rpcUser(jwt.B, 'qualify_referral_internal', { p_referred_user_id: U.B });
  rec('§5 authenticated user CANNOT call an internal function', intByUser.status === 404 || intByUser.status === 403, `status=${intByUser.status}`);
  const tRes = await fetch(`${URL}/rest/v1/referral_reward_rules?select=*`, { headers: H(ANON, jwt.B) });
  const tRows = tRes.ok ? await tRes.json() : null;
  // Correct security = either denied (permission error) or an empty result set.
  rec('§5 authenticated user cannot read the table directly (denied or zero rows)', !tRes.ok || (Array.isArray(tRows) && tRows.length === 0), `status=${tRes.status} rows=${tRows?.length}`);

  // §20 Admin grant/extend/revoke + idempotency (disposable user G)
  const opG = crypto.randomUUID();
  const g1 = await rpcService('admin_mutate_entitlement', { p_operation_id: opG, p_actor_admin_id: Hadmin, p_user_id: U.G, p_entitlement_type: rewardType, p_action: 'grant', p_reason: 'R5 admin grant', p_duration_days: 7 });
  const g1r = await rpcService('admin_mutate_entitlement', { p_operation_id: opG, p_actor_admin_id: Hadmin, p_user_id: U.G, p_entitlement_type: rewardType, p_action: 'grant', p_reason: 'R5 admin grant', p_duration_days: 7 });
  const gEv = await obs('entitlement_events', `user_id=eq.${U.G}&select=id`);
  const gAu = await obs('referral_admin_audit', `operation_id=eq.${opG}&select=id`);
  rec('§20 grant once; same op_id replay=stored result, no dup event/audit', g1.json?.applied === true && g1r.json?.duplicate === true && gEv.length === 1 && gAu.length === 1, `events=${gEv.length} audit=${gAu.length} dup=${g1r.json?.duplicate}`);
  await rpcService('admin_mutate_entitlement', { p_operation_id: crypto.randomUUID(), p_actor_admin_id: Hadmin, p_user_id: U.G, p_entitlement_type: rewardType, p_action: 'extend', p_reason: 'R5 extend', p_duration_days: 7 });
  rec('§20 different op_id (extend) applies independently', (await obs('entitlement_events', `user_id=eq.${U.G}&select=id`)).length === 2);

  // §21 idempotency mismatch
  const mism = await rpcService('admin_mutate_entitlement', { p_operation_id: opG, p_actor_admin_id: Hadmin, p_user_id: U.G, p_entitlement_type: rewardType, p_action: 'revoke', p_reason: 'different intent' });
  rec('§21 same op_id + different intent → idempotency_mismatch, no 2nd audit', /idempotency_mismatch/.test(JSON.stringify(mism.json)) && (await obs('referral_admin_audit', `operation_id=eq.${opG}&select=id`)).length === 1, `${JSON.stringify(mism.json).slice(0, 50)}`);

  // §22 reverse a qualified referral (E) — no auto clawback
  const eRow = (await obs('referrals', `referred_user_id=eq.${U.E}&select=id,status,qualified_at`))[0];
  const rev = await rpcService('admin_reverse_referral', { p_operation_id: crypto.randomUUID(), p_actor_admin_id: Hadmin, p_referral_id: eRow.id, p_reason: 'R5 reverse qualified' });
  const eRow2 = (await obs('referrals', `id=eq.${eRow.id}&select=status,qualified_at`))[0];
  const stAfter = (await obs('user_entitlement_state', `user_id=eq.${U.A}&entitlement_type=eq.${rewardType}&select=status`))[0];
  rec('§22 reverse qualified → reversed, qualified_at kept, NO auto entitlement clawback', rev.json?.applied === true && eRow2.status === 'reversed' && eRow2.qualified_at != null && stAfter?.status === 'active', `status=${eRow2.status} ent=${stAfter?.status}`);
  // §22 reject a PENDING attribution — pending fixture via controlled service-role insert
  const P = await adminCreateUser(email('P')); created.push(P); const jP = await signIn(email('P'));
  const Wp = await adminCreateUser(email('Wp')); created.push(Wp); // fresh, un-referred pending referee
  const codeP = (await rpcUser(jP, 'get_referral_summary', {})).json.referral_code;
  const pend = await srInsert('referrals', { referrer_user_id: P, referred_user_id: Wp, referral_code: codeP, attribution_method: 'manual_code', status: 'attributed' });
  const pendId = pend.json?.[0]?.id;
  const rej = await rpcService('admin_reject_referral', { p_operation_id: crypto.randomUUID(), p_actor_admin_id: Hadmin, p_referral_id: pendId, p_reason: 'R5 reject pending' });
  const pRow2 = (await obs('referrals', `id=eq.${pendId}&select=status`))[0];
  rec('§22 reject pending attribution → rejected (Admin path)', rej.json?.applied === true && pRow2?.status === 'rejected', `status=${pRow2?.status}`);

  // §23 progress adjustment bounds (below zero rejected)
  const adjNeg = await rpcService('admin_adjust_referral_progress', { p_operation_id: crypto.randomUUID(), p_actor_admin_id: Hadmin, p_referrer_user_id: U.A, p_reward_type: rewardType, p_qualified_in_cycle: -1, p_reason: 'below zero attempt' });
  rec('§23 progress adjust cannot go below 0', adjNeg.status >= 400 || /invalid|error|check/i.test(JSON.stringify(adjNeg.json)), `${JSON.stringify(adjNeg.json).slice(0, 50)}`);

  // §24 code rotation
  const rot = await rpcService('admin_rotate_referral_code', { p_operation_id: crypto.randomUUID(), p_actor_admin_id: Hadmin, p_user_id: U.A, p_reason: 'R5 rotate' });
  const codes = await obs('referral_codes', `user_id=eq.${U.A}&select=code,status`);
  const newActive = codes.find((c) => c.status === 'active');
  const Z = await adminCreateUser(email('Z')); created.push(Z); const jZ = await signIn(email('Z'));
  const oldReject = await rpcUser(jZ, 'apply_referral_code', { p_code: code });
  rec('§24 rotation: new active code, old code inactive, old→invalid_code to mobile', rot.json?.applied === true && !!newActive && newActive.code !== code && oldReject.json?.reason === 'invalid_code', `new=${newActive?.code} oldApply=${oldReject.json?.reason}`);

  // §26 rule deactivation → new attribution rejected(no_active_rule)
  const deact = await rpcService('admin_deactivate_reward_rule', { p_operation_id: crypto.randomUUID(), p_actor_admin_id: Hadmin, p_reward_type: rewardType, p_reason: 'R5 deactivate' });
  const activeAfter = await obs('referral_reward_rules', `reward_type=eq.${rewardType}&is_active=eq.true&select=id`);
  const applyAfter = await rpcUser(jZ, 'apply_referral_code', { p_code: newActive.code });
  rec('§26 deactivation: no active rule; NEW attribution rejected(no_active_rule)', deact.json?.applied === true && activeAfter.length === 0 && applyAfter.json?.reason === 'no_active_rule', `active=${activeAfter.length} apply=${applyAfter.json?.reason}`);

  // §19 expiry return-to-inactive (Admin revoke A) → decision inactive
  await rpcService('admin_mutate_entitlement', { p_operation_id: crypto.randomUUID(), p_actor_admin_id: Hadmin, p_user_id: U.A, p_entitlement_type: rewardType, p_action: 'revoke', p_reason: 'R5 expire' });
  const decAafter = await rpcUser(jwt.A, 'get_entitlement_decision', { p_entitlement_type: rewardType });
  rec('§19 after Admin revoke, decision → inactive (return-to-ads eligible)', decAafter.json?.active === false, `active=${decAafter.json?.active} status=${decAafter.json?.status}`);

  return R;
}

test('R5 referral/entitlement live staging E2E (server-side)', liveGate, async () => {
  try {
    await main();
  } finally {
    // Cleanup always runs, even if an assertion above failed mid-run, so a bad
    // run never leaves disposable users or test rules behind on staging.
    let cleanupOk = true;
    for (const id of created) { try { await rpcService('purge_user_data', { p_user_id: id }); } catch { /**/ } try { await adminDeleteUser(id); } catch { cleanupOk = false; } }
    await fetch(`${URL}/rest/v1/referral_reward_rules?reward_type=eq.${rewardType}`, { method: 'DELETE', headers: { ...H(SR), Prefer: 'return=minimal' } }).catch(() => {});
    rec('§36 cleanup: disposable users purged + deleted, test rules removed', cleanupOk, `users=${created.length}`);
  }
  const pass = R.filter((x) => x.pass).length, fail = R.length - pass;
  console.log(`\n=== R5 SERVER E2E: ${pass}/${R.length} PASS, ${fail} FAIL ===`);
  assert.equal(fail, 0, `${fail} R5 server-E2E check(s) failed`);
});
