# 27 — Deployment Guide

Related: [05_BACKEND.md](05_BACKEND.md), [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md), [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md).

This is the concrete, step-by-step "how" for deploying each layer. See [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) for the surrounding process/approval discipline this guide assumes.

## 1. Deploying a migration

```bash
cd supabase

# Confirm the next sequential number
ls migrations/ | tail -5
supabase migration list          # local vs remote must already agree before you add a new one

# Preferred: via CLI (keeps history in sync automatically)
supabase db push

# Alternative (hotfix / out-of-band, e.g. via Management API SQL):
# after applying the raw SQL directly, immediately repair history:
supabase migration repair --status applied <version>
supabase migration list          # confirm it now shows applied on both sides
```

Always run the pre- and post-apply verification queries from [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §2/§3 around this step — a migration is not "deployed" until its post-apply state is confirmed, not just "the command didn't error."

## 2. Deploying Edge Functions

```bash
cd supabase

# Determine the affected set — never deploy blindly
grep -rl "_shared/<changed-module>" functions --include="*.ts"

# Deploy only those
supabase functions deploy <function-name>

# Verify version/status after deploying
```

Verification via the Management API (no CLI-only step needed):

```bash
TOKEN=$(cat ~/.supabase/access-token)
curl -s "https://api.supabase.com/v1/projects/<project-ref>/functions" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "
import json,sys
for f in json.load(sys.stdin):
    if f['slug'] in ('<function-1>','<function-2>'):
        print(f\"{f['slug']}: version={f['version']} status={f['status']}\")"
```

Confirm `status == 'ACTIVE'` and that the `version` number incremented from what it was before the deploy.

## 3. Live smoke-testing a deployed function

Follow the pattern in [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §8: register a throwaway QA device, exercise the endpoint with a clearly-QA-prefixed payload ID, verify via SQL, clean up. This is the standard way to confirm a deployment actually works end-to-end without needing a running Flutter app or a physical device.

## 4. Deploying the Flutter app

### 4.1 Local/simulator run (development verification)

```bash
cd app
flutter pub get
flutter gen-l10n
flutter run -d "Mali-iPhone"                       # offline-stub mode
flutter run -d "Mali-iPhone" \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon-key>          # backend-connected
```

### 4.2 Sideload distribution (Codemagic, `ios-unsigned-sideload`)

No paid Apple Developer account required; produces an unsigned IPA distributable via Sideloadly. Used for QA distribution ahead of formal App Store review, or when a paid developer account isn't yet available.

### 4.3 Signed release (Codemagic, `ios-signed-release`)

Requires the Apple Developer Program (needed for the App Groups entitlement the capture pipeline's shared storage depends on). Produces a signed IPA for TestFlight/App Store distribution.

### 4.4 Android

Standard Flutter Android release build process (`flutter build appbundle`/`flutter build apk`), Play Console upload. SMS-permission-related store policy review applies — see [11_TEST_MATRIX.md](11_TEST_MATRIX.md) `ONB-002` context and [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md)'s general caution against changing Android SMS permission handling without separate explicit review.

## 5. Deploying the admin panel

```bash
cd admin
npm install
npm run lint      # must be clean
npm run build     # must succeed
npm start         # production server, port 3001
```

Environment variables (`.env.local`): `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` — the admin panel never uses the service-role key client-side either; its elevated capabilities (managing global feature flags, catalog data) are gated by its own authenticated-user RLS/policy model, not a bypassed credential.

## 6. Order of operations for a coordinated release (backend + app)

```mermaid
flowchart TD
    A[1. Deploy/verify migration] --> B[2. Deploy/verify affected Edge Functions]
    B --> C[3. Live smoke-test the new backend surface\nwith a QA identity]
    C --> D{Backend verified working?}
    D -- no --> E[Stop — fix backend before touching app release]
    D -- yes --> F[4. Build/release the app version\nthat depends on this backend surface]
    F --> G[5. App-side gates: analyze/test/xcodebuild]
    G --> H[6. Distribute (sideload/TestFlight/store)\nor run locally for QA]
    H --> I[7. Manual device QA against the now-live backend]
```

**Never deploy an app version that assumes a backend surface exists before that surface is actually live and verified** — the backend-first ordering above is not optional sequencing, it's a correctness requirement (an app calling a not-yet-existent RPC/column fails for every user who gets that build before the backend catches up).

## 7. Post-deployment verification checklist (every deployment)

- [ ] Migration history synchronized (`supabase migration list`).
- [ ] Deployed function(s) show `ACTIVE` status and an incremented version.
- [ ] Live smoke test passed (§3), QA rows cleaned up afterward.
- [ ] `flutter analyze`/`flutter test` clean if any app code changed as part of this deployment cycle.
- [ ] `xcodebuild` for both `Runner` and `BankMessageShortcuts` schemes succeeds if any native iOS code changed.
- [ ] Global feature-flag state unchanged unless this deployment explicitly intended a flag change ([12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §6).
- [ ] `git status`/`git diff --check` clean, nothing stray left uncommitted that shouldn't be, nothing committed that wasn't explicitly authorized.
