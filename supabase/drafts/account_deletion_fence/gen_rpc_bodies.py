#!/usr/bin/env python3
# DRAFT — NOT APPLIED — requires Astra review and owner approval
#
# Offline, deterministic, stdlib-only source-to-source generator for fence.sql
# section 5 ("restated bodies with admission"). It reads ONLY the historical
# migration files in ../../migrations (read-only), never a database, and never
# executes SQL. Output is spliced between the markers
#     -- >>> GENERATED:BEGIN rpc_bodies
#     -- <<< GENERATED:END rpc_bodies
# in fence.sql, so the migration that is finally reviewed is static SQL text.
# Re-running it on unchanged inputs yields byte-identical output (check with
# `git diff --exit-code` or sha256 after assembly).
#
# Usage (python3 -I gen_rpc_bodies.py [--help | --check | --write]):
#   (no argument)  read-only; identical to --check (reports, exit 1 if a file would change)
#   --help         prints usage; reads/writes nothing
#   --check        read-only; exit 0 if fence.sql and rollback.sql already equal the
#                  generated text, exit 1 if either would change
#   --write        the ONLY mode that rewrites fence.sql / rollback.sql (generated regions)
# Any other argument (including abbreviations of the above) is rejected with exit 2
# before any file is read for writing. See DECISIONS.md (Q22).
#
# What it does per target function:
#   * finds the LAST `create [or replace] function` for the name in migration
#     order and copies the statement verbatim (header, attributes, body);
#   * inserts only the admission/revalidation lines listed in SPECS, each
#     tagged `-- [fence]`, at the stated anchors (never between a statement and
#     its FOUND/ROW_COUNT check — PERFORM overwrites FOUND);
#   * records the migration file:line range, sha256 of the verbatim statement
#     and md5 of the original body text (== pg_proc.prosrc when the deployed
#     function came from that file) for the drift preflight emitted first.
# Handwritten replacements (LANGUAGE sql -> plpgsql rewrites) are templates
# below and are flagged as such.

import argparse
import glob
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MIG = os.path.normpath(os.path.join(HERE, '..', '..', 'migrations'))
FENCE = os.path.join(HERE, 'fence.sql')
BEGIN_MARK = '-- >>> GENERATED:BEGIN rpc_bodies'
END_MARK = '-- <<< GENERATED:END rpc_bodies'

HDR = re.compile(r'^\s*create\s+(or\s+replace\s+)?function\s+(?:public\.)?("?[a-z_0-9]+"?)\s*\(', re.I)


def load_defs():
    defs = []
    for f in sorted(glob.glob(os.path.join(MIG, '*.sql'))):
        lines = open(f, encoding='utf-8').read().split('\n')
        i = 0
        while i < len(lines):
            m = HDR.match(lines[i])
            if not m:
                i += 1
                continue
            name = m.group(2).strip('"').lower()
            j, tag = i, None
            while j < len(lines):
                mm = re.search(r'\bas\s+(\$[a-z_0-9]*\$)', lines[j], re.I) or \
                     re.search(r'^\s*(\$[a-z_0-9]*\$)\s*$', lines[j])
                if mm:
                    tag = mm.group(1)
                    break
                j += 1
            if tag is None:
                i += 1
                continue
            first = lines[j]
            rest = first[first.find(tag) + len(tag):]
            if tag in rest:
                end = j
            else:
                k = j + 1
                while k < len(lines) and tag not in lines[k]:
                    k += 1
                end = k
            defs.append(dict(name=name, file=os.path.basename(f), start=i + 1, end=end + 1,
                             text='\n'.join(lines[i:end + 1]), tag=tag))
            i = end + 1
    return defs


DEFS = load_defs()


def last_def(name):
    c = [d for d in DEFS if d['name'] == name]
    if not c:
        raise SystemExit('no definition found for %s' % name)
    return c[-1]


def body_of(d):
    t, tag = d['text'], d['tag']
    a = t.find(tag) + len(tag)
    b = t.rfind(tag)
    return t[a:b]


# ---------------------------------------------------------------------------
# SPECS: name, signature (for to_regprocedure in the preflight), kind, edits.
#   begin  : lines inserted after the first top-level BEGIN
#   before : list of (anchor-regex, lines) inserted BEFORE the first line that
#            matches the anchor (after BEGIN)
#   replace: list of (exact-line-substring, replacement-line)
# kinds: 'A' authenticated INVOKER, 'D' DEFINER (see inventory.md)
# ---------------------------------------------------------------------------
ADM_SELF = ['perform account_fence.admit_self();']
ADM_UID = ['perform account_fence.admit(auth.uid());']
RETIRE_LINE = "raise exception 'feature_retired' using errcode = 'QD040';"

SPECS = [
    # --- authenticated INVOKER financial RPCs (caller authorization unchanged)
    dict(name='set_default_account', sig='public.set_default_account(uuid)', begin=ADM_SELF),
    dict(name='add_goal_contribution',
         sig='public.add_goal_contribution(uuid,text,text,numeric,timestamp with time zone,text)', begin=ADM_SELF),
    dict(name='record_bill_payment',
         sig='public.record_bill_payment(uuid,uuid,text,text,numeric,text,timestamp with time zone,timestamp with time zone,timestamp with time zone,integer,text)',
         begin=ADM_SELF),
    dict(name='delete_bill_payment', sig='public.delete_bill_payment(uuid)', begin=ADM_SELF),
    dict(name='delete_user_account_safely', sig='public.delete_user_account_safely(uuid)', begin=ADM_SELF),
    dict(name='create_subscription_and_record_payment', sig=None, begin=ADM_SELF),
    dict(name='delete_user_category_safely', sig='public.delete_user_category_safely(uuid)', begin=ADM_SELF),
    dict(name='import_financial_package', sig='public.import_financial_package(text,text,jsonb)', begin=ADM_SELF),
    dict(name='mark_onboarding_completed', sig='public.mark_onboarding_completed()', begin=ADM_SELF),
    # --- authenticated DEFINER RPCs
    dict(name='record_engagement_event',
         sig='public.record_engagement_event(uuid,text,timestamp with time zone,text,integer)', begin=ADM_UID),
    dict(name='record_metric', sig='public.record_metric(text,text)', begin=ADM_UID),
    dict(name='commit_backup_generation',
         sig='public.commit_backup_generation(text,text,integer,bigint,text,text,text)', begin=ADM_UID),
    # D6 (owner decision 2026-10-24, DELETION-COMPLETION-CONTRACT.md section 10): the old referral/entitlement
    # protocol is PERMANENTLY RETIRED. Every writer below refuses first with QD040 'feature_retired' and has no
    # side effect (no admission, no lock, no read). Existing entitlement rows are preserved untouched.
    # get_referral_summary stays a READ path: code CREATION (ensure_referral_code) is retired, so the summary
    # now reads the existing active code (null when none) instead of minting one.
    dict(name='get_referral_summary', sig='public.get_referral_summary()', begin=ADM_UID,
         replace=[('v_code := public.ensure_referral_code(v_uid);',
                   "select code into v_code from public.referral_codes where user_id = v_uid and status = 'active';",
                   'D6: read the existing code only; creation is retired')]),
    dict(name='ensure_referral_code', sig='public.ensure_referral_code(uuid)', retire=True),
    dict(name='apply_entitlement_mutation',
         sig='public.apply_entitlement_mutation(text,uuid,text,text,text,integer,text,uuid,integer,integer,uuid,text)',
         retire=True),
    dict(name='apply_referral_code', sig='public.apply_referral_code(text)', retire=True),
    dict(name='request_referral_qualification', sig='public.request_referral_qualification()', retire=True),
    dict(name='qualify_referral_internal', sig='public.qualify_referral_internal(uuid)', retire=True),
    dict(name='admin_mutate_entitlement',
         sig='public.admin_mutate_entitlement(text,uuid,uuid,text,text,text,integer)', retire=True),
    dict(name='admin_reject_referral', sig='public.admin_reject_referral(text,uuid,uuid,text)', retire=True),
    dict(name='admin_reverse_referral', sig='public.admin_reverse_referral(text,uuid,uuid,text)', retire=True),
    dict(name='admin_adjust_referral_progress',
         sig='public.admin_adjust_referral_progress(text,uuid,uuid,text,integer,text)', retire=True),
    dict(name='admin_rotate_referral_code', sig='public.admin_rotate_referral_code(text,uuid,uuid,text)', retire=True),
    dict(name='admin_publish_reward_rule',
         sig='public.admin_publish_reward_rule(text,uuid,text,integer,integer,boolean,text,timestamp with time zone)',
         retire=True),
    dict(name='admin_deactivate_reward_rule', sig='public.admin_deactivate_reward_rule(text,uuid,text,text)', retire=True),
    # --- capture (O2 narrowing, O4 install owners)
    dict(name='link_capture_device',
         sig='public.link_capture_device(text,text,boolean,boolean,integer,bigint)',
         begin=ADM_UID + ['perform account_fence.admit_install(p_install_id_hash, false, true);']),
    dict(name='set_capture_consent',
         sig='public.set_capture_consent(text,text,boolean,boolean,integer,bigint)',
         begin=['perform account_fence.admit(auth.uid(), true, true);',
                'perform account_fence.admit_install(p_install_id_hash, true);'],
         before=[(r'^\s*if v_blocked is not null then',
                  ["if v_blocked is null and account_fence.is_pending(v_uid) then",
                   "  v_blocked := 'deletion_pending';  -- O2: pending account may only narrow",
                   "end if;"])]),
    dict(name='revoke_capture_consent',
         sig='public.revoke_capture_consent(text,text,uuid,bigint,integer)',
         begin=['perform account_fence.admit(auth.uid(), true, true);',
                'perform account_fence.admit_install(p_install_id_hash, true);']),
    dict(name='legacy_link_capture_device', sig='public.legacy_link_capture_device(text,uuid)',
         begin=['perform account_fence.admit(p_user_id);', 'perform account_fence.admit_install(p_install_id_hash, false, true);']),
    dict(name='legacy_set_device_consent', sig='public.legacy_set_device_consent(text,boolean,boolean)',
         begin=['perform account_fence.admit_install(p_install_id_hash, true);'],
         before=[(r'^\s*if v_row\.last_revoke_generation is not null then',
                  ["if account_fence.is_pending(v_row.user_id) then",
                   "  v_cloud := v_cloud and v_row.cloud_processing_enabled;  -- O2: pending account may only narrow",
                   "  v_ai := v_ai and v_row.ai_consent_granted;",
                   "end if;"])]),
    dict(name='unlink_capture_device', sig='public.unlink_capture_device(text)',
         begin=['perform account_fence.admit_install(p_install_id_hash, true, true);',
                'perform account_fence.assert_unlink_allowed(p_install_id_hash);']),
    dict(name='capture_claim',
         sig='public.capture_claim(text,text,text,text,uuid,integer,integer,bigint)',
         begin=['perform account_fence.admit_install(p_install_id_hash);', 'perform account_fence.admit(p_owner_uid);']),
    dict(name='capture_ai_dispatch', sig='public.capture_ai_dispatch(text,text,integer)',
         begin=['perform account_fence.admit_install(p_install_id_hash);']),
    dict(name='capture_finalize',
         sig='public.capture_finalize(text,text,text,integer,text,text,jsonb,jsonb,text,text,boolean,jsonb)',
         begin=['perform account_fence.admit_install(p_install_id_hash);']),
    dict(name='capture_ack', sig='public.capture_ack(text,uuid,text[])',
         begin=['perform account_fence.admit_install(p_install_id_hash);', 'perform account_fence.admit(p_user_id);']),
    dict(name='capture_retry_fence', sig='public.capture_retry_fence(text,text)',
         begin=['perform account_fence.admit_install(p_install_id_hash);']),
    dict(name='capture_queue_push', sig='public.capture_queue_push(text,text,text,uuid,text)',
         begin=['perform account_fence.admit_install(p_install_id_hash);', 'perform account_fence.admit(p_user_id);']),
    dict(name='capture_revoke_fanout', sig='public.capture_revoke_fanout(text,uuid,boolean,boolean,integer)',
         begin=[],
         replace=[('if p_user_id is not null then',
                   'if p_user_id is not null and not account_fence.is_pending(p_user_id) then'
                   '  -- [fence] O2: no settings-mirror write for a pending account')]),
    # --- ai idempotency (key grammar), award ledger
    dict(name='claim_ai_idempotency', sig='public.claim_ai_idempotency(text,text,text,text,integer)',
         begin=['perform account_fence.admit_owner_key(p_owner_key);']),
    dict(name='award_gamification_for_transaction', sig='public.award_gamification_for_transaction(text,uuid)',
         begin=['perform account_fence.admit(p_user_id);']),
]

# Handwritten plpgsql replacements for LANGUAGE sql originals (body semantics
# identical; the single statement is wrapped so a statement can precede it).
TEMPLATES = {
    'bump_capture_rate_limit': dict(
        sig='public.bump_capture_rate_limit(text,integer)',
        text='''create or replace function bump_capture_rate_limit(
  p_install_id_hash TEXT,
  p_limit INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_over boolean;
begin
  perform account_fence.admit_rate_key(p_install_id_hash);  -- [fence] exact grammar or reject
  INSERT INTO capture_rate_limits AS r (install_id_hash, date, call_count)
  VALUES (p_install_id_hash, CURRENT_DATE, 1)
  ON CONFLICT (install_id_hash, date)
    DO UPDATE SET call_count = r.call_count + 1
  RETURNING call_count > p_limit INTO v_over;
  return v_over;
end;
$$;'''),
    'complete_ai_idempotency': dict(
        sig='public.complete_ai_idempotency(text,text,text,text,jsonb)',
        text='''create or replace function complete_ai_idempotency(
  p_owner_key TEXT,
  p_endpoint TEXT,
  p_request_id TEXT,
  p_status TEXT,
  p_result JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
begin
  perform account_fence.admit_owner_key(p_owner_key);  -- [fence] exact grammar or reject
  UPDATE ai_request_idempotency
    SET status = p_status, result = COALESCE(p_result, '{}'::jsonb)
  WHERE owner_key = p_owner_key
    AND endpoint = p_endpoint
    AND request_id = p_request_id;
end;
$$;'''),
}
TEMPLATE_ORIGIN = {'bump_capture_rate_limit': 'bump_capture_rate_limit',
                   'complete_ai_idempotency': 'complete_ai_idempotency'}


ALIASES = {'timestamptz': 'timestamp with time zone', 'int': 'integer', 'int4': 'integer', 'int8': 'bigint',
           'bool': 'boolean', 'varchar': 'character varying'}


def header_arg_types(d):
    t = d['text']
    a = t.find('(')
    depth, i = 0, a
    while True:
        c = t[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                break
        i += 1
    inner = t[a + 1:i]
    parts, cur, dp = [], '', 0
    for ch in inner:
        if ch == '(':
            dp += 1
        elif ch == ')':
            dp -= 1
        if ch == ',' and dp == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    types = []
    for p in parts:
        p = re.split(r'\s+default\s+|\s*=\s*', p.strip(), flags=re.I)[0].strip()
        p = re.sub(r'^(in|inout)\s+', '', p, flags=re.I)
        toks = p.split(None, 1)
        ty = toks[1].strip().lower() if len(toks) > 1 else ''
        ty = re.sub(r'^public\.', '', ty)
        ty = re.sub(r'\s+', ' ', ty)
        base = ty.replace('[]', '')
        base = ALIASES.get(base, base)
        types.append(base + ('[]' if ty.endswith('[]') else ''))
    return types


def check_sig(sig, d):
    inner = sig[sig.find('(') + 1:sig.rfind(')')]
    want = [x.strip() for x in inner.split(',')] if inner.strip() else []
    # re-join multiword types split by commas never occur (no commas inside our type names)
    got = header_arg_types(d)
    if want != got:
        raise SystemExit('signature mismatch for %s: spec %s vs source %s' % (sig, want, got))


def apply_edits(d, spec):
    lines = d['text'].split('\n')
    # first top-level BEGIN after the opening dollar quote
    open_idx = next(i for i, l in enumerate(lines)
                    if re.search(r'\bas\s+\$[a-z_0-9]*\$', l, re.I) or re.match(r'^\s*\$[a-z_0-9]*\$\s*$', l))
    begin_idx = next(i for i in range(open_idx, len(lines)) if re.match(r'^\s*begin\b', lines[i], re.I))
    ind = '  '
    out = lines[:begin_idx + 1]
    body = lines[begin_idx + 1:]
    if spec.get('retire'):
        # D6: first statement after BEGIN, nothing before it, nothing after it is reachable.
        out += [ind + RETIRE_LINE + '  -- [fence] D6: referral/entitlement protocol retired (QD040)']
    out += [ind + l + '  -- [fence]' for l in spec.get('begin', [])]
    for (anchor, add) in spec.get('before', []):
        pat = re.compile(anchor, re.I)
        pos = next((i for i, l in enumerate(body) if pat.match(l)), None)
        if pos is None:
            raise SystemExit('%s: anchor not found: %s' % (spec['name'], anchor))
        body = body[:pos] + [ind + l + '  -- [fence]' for l in add] + body[pos:]
    for rep in spec.get('replace', []):
        needle, repl = rep[0], rep[1]
        note = rep[2] if len(rep) > 2 else 'O2: no settings-mirror write for a pending account'
        pos = next((i for i, l in enumerate(body) if needle in l), None)
        if pos is None:
            raise SystemExit('%s: replace target not found: %s' % (spec['name'], needle))
        body[pos] = body[pos].replace(needle, repl.split('  -- [fence]')[0]) + '  -- [fence] ' + note
    return '\n'.join(out + body)


# ---------------------------------------------------------------------------
# E3: expected pg_proc attributes of the DEPLOYED function, read from the header
# of the migration statement that created it (no ALTER FUNCTION exists in the
# migration set). CREATE OR REPLACE re-sets every attribute from the statement,
# so a deployed attribute that differs from the statement would be silently
# overwritten; fence.sql therefore compares them before changing anything.
# ---------------------------------------------------------------------------
OPEN_RE = re.compile(r'\bas\s+\$[a-z_0-9]*\$|^\s*\$[a-z_0-9]*\$\s*$', re.I | re.M)


def header_of(d):
    t = d['text']
    m = OPEN_RE.search(t)
    if not m:
        raise SystemExit('no body opener in %s:%d' % (d['file'], d['start']))
    return re.sub(r'--[^\n]*', '', t[:m.start()])


def parse_attrs(d):
    h = header_of(d)
    low = h.lower()
    lang = re.search(r'\blanguage\s+([a-z_0-9]+)', low)
    if not lang:
        raise SystemExit('no LANGUAGE in %s:%d' % (d['file'], d['start']))
    sec = re.search(r'\bsecurity\s+(definer|invoker)', low)
    vol = re.search(r'\b(immutable|stable|volatile)\b', low)
    par = re.search(r'\bparallel\s+(safe|restricted|unsafe)\b', low)
    cost = re.search(r'\bcost\s+(\d+)', low)
    sets = re.findall(r'\bset\s+([a-z_0-9.]+)\s*(?:=|\bto\b)\s*([^\n]*?)\s*(?=\n|$)', h, re.I)
    n_set_words = len(re.findall(r'\bset\s+[a-z_0-9.]+\s*(?:=|\bto\b)', low))
    if n_set_words != len(sets):
        raise SystemExit('unmodelled SET clause in %s:%d' % (d['file'], d['start']))
    cfg = []
    for name, val in sets:
        items = [x.strip().strip('"\'').lower() for x in val.split(',')]
        cfg.append('%s=%s' % (name.lower(), ','.join(items)))
    return dict(
        lang=lang.group(1),
        secdef=(sec.group(1) == 'definer') if sec else False,
        vol={'volatile': 'v', 'stable': 's', 'immutable': 'i'}[vol.group(1)] if vol else 'v',
        strict=bool(re.search(r'\bstrict\b|returns\s+null\s+on\s+null\s+input', low)),
        par={'unsafe': 'u', 'safe': 's', 'restricted': 'r'}[par.group(1)] if par else 'u',
        leak=bool(re.search(r'(?<!not\s)\bleakproof\b', low)),
        cost=int(cost.group(1)) if cost else 100,
        cfg=';'.join(cfg) if cfg else None,
    )


def attr_preflight(pre_attrs):
    """pre_attrs: list of (sig, attrs dict). Returns the DO block text."""
    def q(v):
        return 'null::text' if v is None else "'%s'" % v.replace("'", "''")
    rows = []
    for sig, a in pre_attrs:
        rows.append("    ('%s', '%s', %s, '%s', %s, '%s', %s, %d, %s)" % (
            sig, a['lang'], 'true' if a['secdef'] else 'false', a['vol'],
            'true' if a['strict'] else 'false', a['par'], 'true' if a['leak'] else 'false',
            a['cost'], q(a['cfg'])))
    out = [
        '-- E3: attributes that CREATE OR REPLACE would overwrite must already equal the migration statement.',
        '-- Expected values are derived offline from each statement header by gen_rpc_bodies.py; the catalog',
        '-- columns and the captured pg_get_functiondef text (rollback_function_snapshot.fn_def) must agree.',
        'do $attr$',
        'declare r record; p pg_catalog.pg_proc%rowtype; s account_fence.rollback_function_snapshot%rowtype; v_cfg text; v_lang text;',
        'begin',
        '  for r in select * from (values',
        ',\n'.join(rows),
        '  ) as t(sig, lang, secdef, vol, is_strict, par, leak, cost, cfg) loop',
        '    select * into p from pg_catalog.pg_proc where oid = to_regprocedure(r.sig);',
        '    if p.oid is null then',
        "      raise exception 'account_fence preflight: signature does not resolve: %', r.sig using errcode = 'QD090';",
        '    end if;',
        '    select * into s from account_fence.rollback_function_snapshot where fn_identity = p.oid::regprocedure::text;',
        '    if s.fn_identity is null then',
        "      raise exception 'account_fence preflight: function missing from rollback snapshot: %', r.sig using errcode = 'QD094';",
        '    end if;',
        '    select l.lanname into v_lang from pg_catalog.pg_language l where l.oid = p.prolang;',
        "    v_cfg := replace(replace(replace(lower(pg_catalog.array_to_string(p.proconfig, ';')), ' ', ''), '\"', ''), '''', '');",
        '    if v_lang is distinct from r.lang',
        '       or p.prosecdef is distinct from r.secdef',
        '       or p.provolatile::text is distinct from r.vol',
        '       or p.proisstrict is distinct from r.is_strict',
        '       or p.proparallel::text is distinct from r.par',
        '       or p.proleakproof is distinct from r.leak',
        '       or p.procost::numeric is distinct from r.cost::numeric',
        '       or v_cfg is distinct from r.cfg then',
        "      raise exception 'account_fence preflight: deployed attributes differ from the migration statement (drift): %', r.sig using errcode = 'QD094';",
        '    end if;',
        '    -- the captured definition text must agree with the catalog row it was taken from',
        "    if (position(' SECURITY DEFINER' in s.fn_def) > 0) is distinct from r.secdef",
        "       or position(' LANGUAGE ' || r.lang || E'\\n' in s.fn_def) = 0 then",
        "      raise exception 'account_fence preflight: captured pg_get_functiondef disagrees with expected attributes: %', r.sig using errcode = 'QD094';",
        '    end if;',
        '  end loop;',
        'end',
        '$attr$;',
        '',
    ]
    return '\n'.join(out)


def sha(s, kind='sha256'):
    return getattr(hashlib, kind)(s.encode('utf-8')).hexdigest()


def parse_cli(argv):
    ap = argparse.ArgumentParser(
        prog='gen_rpc_bodies.py', allow_abbrev=False,
        description='Offline provenance generator for fence.sql / rollback.sql generated regions. '
                    'Read-only unless --write is given.')
    g = ap.add_mutually_exclusive_group()
    g.add_argument('--check', action='store_true',
                   help='read-only: exit 0 if both files already equal the generated text, 1 otherwise')
    g.add_argument('--write', action='store_true',
                   help='rewrite the generated regions in fence.sql and rollback.sql (the only writing mode)')
    return ap.parse_args(argv)


def main():
    args = parse_cli(sys.argv[1:])
    check = not args.write      # default (no argument) and --check never write
    gen = []
    pre = []   # (regprocedure, md5(prosrc), file:start-end)
    pre_attrs = []  # (regprocedure, expected attribute dict of the deployed function)

    # Functions that fence.sql restates BY HAND (not generated) but must also
    # be drift-checked. Keep in sync with fence.sql sections 3, 4d, 7, 9.
    handwritten = [
        ('stamp_sync_seq', 'public.stamp_sync_seq()'),
        ('sync_lock_epoch', 'public.sync_lock_epoch()'),
        ('backups_owner_is_live', 'public.backups_owner_is_live()'),
        ('request_account_deletion', 'public.request_account_deletion()'),
        ('cancel_account_deletion', 'public.cancel_account_deletion()'),
        ('feature_flag_audit_append_only', 'public.feature_flag_audit_append_only()'),
    ]
    for name, sig in handwritten:
        d = last_def(name)
        check_sig(sig, d)
        pre.append((sig, sha(body_of(d), 'md5'), '%s:%d-%d' % (d['file'], d['start'], d['end'])))
        pre_attrs.append((sig, parse_attrs(d)))

    gen.append('-- Generated by gen_rpc_bodies.py from supabase/migrations (read-only). Do not hand-edit.')
    gen.append('-- Every line added to a verbatim body carries the tag `-- [fence]`; `diff` against the cited')
    gen.append('-- migration range must show nothing else.')
    gen.append('')

    blocks = []
    for spec in SPECS:
        d = last_def(spec['name'])
        sig = spec['sig']
        if sig is None and spec['name'] == 'create_subscription_and_record_payment':
            sig = ('public.create_subscription_and_record_payment(text,text,text,numeric,text,text,text,'
                   'timestamp with time zone,timestamp with time zone,uuid,text,boolean,boolean,integer,text,text,'
                   'integer,integer,numeric,numeric,text,numeric,numeric,timestamp with time zone,'
                   'timestamp with time zone,timestamp with time zone,integer,text)')
        check_sig(sig, d)
        pre.append((sig, sha(body_of(d), 'md5'), '%s:%d-%d' % (d['file'], d['start'], d['end'])))
        pre_attrs.append((sig, parse_attrs(d)))
        text = apply_edits(d, spec)
        blocks.append('-- [gen] %s\n--   source: supabase/migrations/%s:%d-%d\n--   verbatim statement sha256: %s\n'
                      '--   original body md5 (pg_proc.prosrc preflight): %s\n%s\n' % (
                          sig, d['file'], d['start'], d['end'], sha(d['text']), sha(body_of(d), 'md5'), text))
    for name, t in TEMPLATES.items():
        d = last_def(TEMPLATE_ORIGIN[name])
        check_sig(t['sig'], d)
        pre.append((t['sig'], sha(body_of(d), 'md5'), '%s:%d-%d' % (d['file'], d['start'], d['end'])))
        orig_a = parse_attrs(d)
        pre_attrs.append((t['sig'], orig_a))
        # the hand-written replacement may change LANGUAGE only; every other attribute must equal the original
        tmpl_a = parse_attrs(dict(d, text=t['text']))
        for k in orig_a:
            if k != 'lang' and orig_a[k] != tmpl_a[k]:
                raise SystemExit('template %s changes attribute %s' % (t['sig'], k))
        blocks.append('-- [gen/template] %s  (LANGUAGE sql original rewritten as plpgsql, same statement)\n'
                      '--   source: supabase/migrations/%s:%d-%d\n--   verbatim statement sha256: %s\n'
                      '--   original body md5 (pg_proc.prosrc preflight): %s\n%s\n' % (
                          t['sig'], d['file'], d['start'], d['end'], sha(d['text']), sha(body_of(d), 'md5'), t['text']))

    # preflight DO block
    pf = ['do $chk$', 'declare r record; v_md5 text; v_owner text;', 'begin',
          "  for r in select * from (values"]
    rows = []
    for sig, md5, src in pre:
        rows.append("    ('%s', '%s', '%s')" % (sig, md5, src))
    pf.append(',\n'.join(rows))
    pf += [
        "  ) as t(sig, expected_md5, src) loop",
        "    select md5(p.prosrc), pg_catalog.pg_get_userbyid(p.proowner)",
        "      into v_md5, v_owner",
        "      from pg_catalog.pg_proc p where p.oid = to_regprocedure(r.sig);",
        "    if v_md5 is null then",
        "      raise exception 'account_fence preflight: signature does not resolve: %', r.sig using errcode = 'QD090';",
        "    end if;",
        "    if v_md5 <> r.expected_md5 then",
        "      raise exception 'account_fence preflight: deployed body differs from %: %', r.src, r.sig using errcode = 'QD091';",
        "    end if;",
        "    if v_owner <> current_user then",
        "      raise exception 'account_fence preflight: % is owned by %, expected %', r.sig, v_owner, current_user using errcode = 'QD092';",
        "    end if;",
        "  end loop;",
        "end",
        "$chk$;",
        '',
    ]
    pre_sql = '\n'.join(pf)
    bodies = '\n'.join(gen) + '\n' + '\n'.join(blocks)

    # rollback: verbatim ORIGINAL statements, literal
    rb = ['-- Generated by gen_rpc_bodies.py: verbatim original statements (CREATE OR REPLACE keeps OID and ACL).']
    seen = set()
    for spec in SPECS:
        d = last_def(spec['name'])
        rb.append('-- %s:%d-%d\n%s\n' % (d['file'], d['start'], d['end'], d['text']))
    for name in TEMPLATES:
        d = last_def(TEMPLATE_ORIGIN[name])
        rb.append('-- %s:%d-%d\n%s\n' % (d['file'], d['start'], d['end'], d['text']))
    rb_sql = '\n'.join(rb)

    results = []
    for path, regions in ((FENCE, {'rpc_preflight': pre_sql, 'rpc_attr_preflight': attr_preflight(pre_attrs), 'rpc_bodies': bodies}),
                          (os.path.join(HERE, 'rollback.sql'), {'rpc_originals': rb_sql})):
        src = open(path, encoding='utf-8').read()
        new = src
        for key, payload in regions.items():
            bm = '-- >>> GENERATED:BEGIN ' + key
            em = '-- <<< GENERATED:END ' + key
            a, b = new.find(bm), new.find(em)
            if a < 0 or b < 0 or b < a:
                raise SystemExit('markers missing: %s in %s' % (key, path))
            new = new[:a + len(bm)] + '\n' + payload + '\n' + new[b:]
        results.append((path, src, new))
    if check:
        same = all(a == b for _, a, b in results)
        print('check: generated regions %s' % ('match' if same else 'DIFFER (nothing written)'))
        sys.exit(0 if same else 1)
    for path, _, new in results:
        open(path, 'w', encoding='utf-8').write(new)
    print('spliced %d generated functions, %d preflight rows' % (len(SPECS) + len(TEMPLATES), len(pre)))


if __name__ == '__main__':
    main()
