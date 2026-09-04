# Qirsh — Codemagic environment inventory

**As of 2026-09-04.** The single authoritative list of every variable a Codemagic
build consumes, so Codemagic is configured **once**, at the end, rather than
repeatedly discovering a missing value mid-release.

**No secret value appears in this document, and none ever should.** Names,
shapes, provenance and status only. Public identifiers are described by shape and
written as placeholders unless the literal is already public on the internet.

**Codemagic configuration is a FINAL release-preparation action.** Do not
populate it until every external credential exists. When it is complete this file
will say so at the top.

> **STATUS: NOT READY FOR SETUP.** Outstanding external items are listed in
> §5. Normal release work continues; this inventory is updated whenever a new
> required variable is discovered.

---

## 0. How to read this

**Status values**

`READY` — the value exists and is known to the owner.
`MISSING` — required, does not exist yet.
`DEFERRED` — deliberately not supplied; a build must run without it.
`N/A` — not a Codemagic variable (listed to prevent it being added there).

**"Exists in Codemagic?"** is answered only where it can be established from this
repository or from a build that has actually run. Codemagic's stored variables
cannot be read from here, so most rows say *unknown — verify in UI*. That is an
honest gap, not an oversight.

**Fail-closed** is the most important column. Every ad, sync and telemetry path in
Qirsh is built to degrade to "off" rather than to break, so an absent variable
almost never breaks a build — it silently disables a feature. That is exactly why
a written inventory is needed.

---

## 1. Groups that must exist

| Group | Purpose | Attach to | NEVER attach to |
|---|---|---|---|
| `supabase` | Backend URL + anon key, legal URL, Sentry | the **three release** workflows only | not needed on `backend-and-quality-gates` (it passes no dart-defines) |
| `google_play` | Android **upload-key** material | `android-release` | any iOS or quality workflow |
| `admob` **(does not exist yet)** | The six production AdMob identifiers | `android-release`, `ios-signed-release` | **`backend-and-quality-gates`** — a test enforces this |
| `apple` *(optional; see §3)* | Only if ASC is not wired via the Codemagic integration | `ios-signed-release` | Android + quality workflows |

Groups currently referenced in `codemagic.yaml`: **`supabase`**, **`google_play`**.
`admob` is new. There is **no** `apple` group today — iOS signing uses Codemagic's
native `ios_signing` / `app_store_connect` integration instead (§3).

---

## 2. Shared / backend — group `supabase`

Consumed by the **three release workflows** as `--dart-define`.

**`backend-and-quality-gates` needs no variables at all.** Verified 2026-09-04:
its `environment:` block declares only `flutter` and `java`, with **no `groups:`**,
and it passes **zero** dart-defines — it runs the canonical gates and compiles
debug artifacts, which need no backend and no signing. That is the property that
makes it safe to trigger automatically on every push, and it should be preserved.

| Variable | Platform | Secure | Required | Exists? | Shape | Source | Status | Fails closed as |
|---|---|---|---|---|---|---|---|---|
| `SUPABASE_URL` | shared | **NO** (public) | **Required** | yes — builds succeed | `https://<ref>.supabase.co` | Supabase → Project Settings → API | **READY** | No backend at all: sync, catalog delta, AI assist, entitlement all dead |
| `SUPABASE_ANON_KEY` | shared | **YES** | **Required** | yes | long JWT (`eyJ…`) | same page | **READY** | as above |
| `LEGAL_BASE_URL` | shared | NO | Optional | unknown — verify in UI | `https://qirsh.site` | own domain | **READY** | Falls back to the built-in default, which is already `https://qirsh.site` (`legal_urls.dart`). Safe to omit |
| `SENTRY_DSN` | shared | **YES** | Optional | unknown — verify in UI | `https://<key>@<org>.ingest.sentry.io/<id>` | Sentry project settings | **MISSING** | No crash reporting. Nothing else breaks |
| `APP_VERSION` | shared | NO | Optional | set by CI | `x.y.z` | supplied by the build | **READY** | Falls back to the pubspec version |

**`SUPABASE_URL` must be the linked production project.** A stale value here is
the same class of mistake as the local `admin/.env.local`, which points at a
**forbidden legacy ref** (see `RELEASE_BLOCKERS.md`). Verify it matches
`supabase/.temp/project-ref` before trusting a release build.

---

## 3. iOS — signing and App Store Connect

**These are NOT plain environment variables.** `codemagic.yaml` uses Codemagic's
native integrations, and adding shadow copies as variables would be a second
source of truth:

```yaml
ios_signing:
  distribution_type: app_store
  bundle_identifier: com.youssefsafwat.mali
app_store_connect: codemagic_asc_api_key      # named ASC key in Codemagic
publishing:
  app_store_connect:
    auth: integration
    submit_to_testflight: true
```

| Item | Where it lives | Secure | Required | Status | Fails closed as |
|---|---|---|---|---|---|
| ASC API key `codemagic_asc_api_key` | Codemagic → Integrations → App Store Connect | managed | **Required for `ios-signed-release`** | **MISSING** — Apple portal access is blocked (2FA) | The signed workflow cannot run at all. `ios-unsigned-sideload` still works |
| iOS distribution certificate + provisioning profile | Codemagic → Code signing identities | managed | Required | **MISSING** — same blocker | Signed build fails; unsigned sideload unaffected |
| `ADMOB_APP_ID_IOS` | group `admob` (§4) | NO | Optional | **MISSING** | See §4 |

**The unsigned workflow is the fallback.** `ios-unsigned-sideload` needs no Apple
credential, which is why it exists — it keeps iOS buildable while the portal is
blocked.

---

## 4. AdMob — group `admob` (to be created)

None of these exist yet, which is precisely why every ad path is currently inert.

| Variable | Platform | Secure | Required | Shape | Status |
|---|---|---|---|---|---|
| `ADMOB_APP_ID_ANDROID` | Android | **YES** | Optional | `ca-app-pub-<16 digits>` **`~`** `<10 digits>` | **MISSING** |
| `ADMOB_APP_ID_IOS` | iOS | **YES** | Optional | same, **tilde** | **MISSING** |
| `ADMOB_BANNER_ANDROID` | Android | **YES** | Optional | `ca-app-pub-<16 digits>` **`/`** `<10 digits>` | **MISSING** |
| `ADMOB_BANNER_IOS` | iOS | **YES** | Optional | same, **slash** | **MISSING** |
| `ADMOB_INTERSTITIAL_ANDROID` | Android | **YES** | Optional | same, **slash** | **MISSING** |
| `ADMOB_INTERSTITIAL_IOS` | iOS | **YES** | Optional | same, **slash** | **MISSING** |

**Application ids use a TILDE; ad-unit ids use a SLASH.** `build.gradle.kts:50`
and `admob_build_config.dart:74-76` enforce both shapes exactly, mirroring what
the native SDK validates at process start.

**Source:** AdMob console → the Qirsh app → App settings (app id) and Ad units
(unit ids). Two apps (Android + iOS) and four units.

**Fails closed as:** no ad is ever requested. A release build with these absent
resolves null and serves nothing, by design — three separate owner actions are
required before an ad can appear.

**Guardrails — a mistake fails the build rather than shipping:**
- A **malformed** `ADMOB_APP_ID_ANDROID` throws `GradleException`; a bad value
  would crash the app at launch via `MobileAdsInitProvider`. The value is never
  echoed.
- Google's **test publisher** (`ca-app-pub-3940256099942544`) in a *release* build
  also fails. Leave the variable unset to build without ads instead.
- **Absent is legal and loud** — the build warns that the release ships with
  monetization off.
- `ADMOB_APP_ID_IOS` additionally reaches the native layer through
  `ios/Flutter/AdMob.xcconfig`, which `codemagic.yaml` writes at build time.
  Android reads its app id from the **environment** in Gradle *as well as* the
  dart-define.

### Related but NOT a Codemagic variable

| Variable | Where | Status |
|---|---|---|
| `ADMOB_PUBLISHER_ID` | **local site tooling only** — `tools/build_site.py` | ✅ **DONE.** `https://qirsh.site/app-ads.txt` is live and verified. **Do not add to Codemagic**; no build consumes it |

---

## 5. Android — group `google_play`

Upload-key material. The keystore is **materialised at build time** from base64
and shredded afterwards; `ANDROID_KEYSTORE_PATH` is produced by that step and must
**not** be stored.

| Variable | Secure | Required | Shape | Source | Status |
|---|---|---|---|---|---|
| `ANDROID_KEYSTORE_BASE64` | **YES** | **Required** for `android-release` | base64 of the upload `.jks` | `base64 -i upload-keystore.jks` locally | **READY** — keystore exists locally, gitignored |
| `ANDROID_KEYSTORE_PASSWORD` | **YES** | **Required** | opaque | set when the keystore was created | **READY** |
| `ANDROID_KEY_ALIAS` | **YES** | **Required** | opaque | same | **READY** |
| `ANDROID_KEY_PASSWORD` | **YES** | **Required** | opaque | same | **READY** |
| ~~`ANDROID_KEYSTORE_PATH`~~ | — | **Never store** | — | produced by the materialisation step | **N/A** |

**Fails closed as:** the release workflow fails rather than emitting an unsigned
or debug-signed AAB — asserted by `android_ci_compile_gate_test.dart`.

**Play App Signing enrolment is still outstanding** (`EXTERNAL_REQUIREMENTS.md`).
There is **no** `google_play` *publishing* block in `codemagic.yaml`: nothing
auto-uploads to Play, which is deliberate while submission is unauthorised.

---

## 6. NOT Codemagic — Supabase Edge secrets

Listed so they are never mistakenly added to Codemagic. These are set with
`supabase secrets set` against the linked project and are consumed by Edge
Functions at runtime, not at build time.

| Secret | Purpose | Status |
|---|---|---|
| `GEMINI_API_KEY` | Cloud AI parse assist | ✅ **SET AND VERIFIED 2026-09-04** (Tier 1 · Prepay, storage OFF) |
| `GEMINI_MODEL` | Model pin | Optional — defaults to `gemini-2.5-flash-lite` |
| `GEMINI_SHADOW_API_KEY` | Proof shadow arm | **CORRECTLY ABSENT** — do not set until the Proof engine has a call site |
| `APNS_PRIVATE_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` | Push delivery | **MISSING** — needs Apple portal access |
| `GOOGLE_MAPS_API_KEY` | Merchant enrichment | **MISSING** |
| `NOTIFICATION_RETRY_WORKER_SECRET`, `PURGE_WORKER_SECRET` | Cron worker auth | ✅ **SET** — verified 2026-09-04 |
| `AFFILIATE_WORKER_SECRET` | Affiliate cron auth | **MISSING** — confirmed absent; keeps 0096's hourly cron inert |
| `AFFILIATE_FIXTURE_POSTBACK_SECRET` | Fixture postbacks | **MISSING** — fixture only |
| `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_URL`, `SUPABASE_ANON_KEY` | Injected by the platform | **N/A** — never set manually |

Vault entries `project_url` and `affiliate_worker_secret` are **absent**, which is
what keeps the affiliate cron inert. Distinct from Edge secrets.

---

## 7. Site deployment — no Codemagic variables

**Codemagic does not deploy the website.** A scan of `codemagic.yaml` for
`rsync`, `qirsh.site`, `build_site`, `cloudflare` and `wrangler` returns **zero**
matches. The site is built locally and deployed by the owner over `rsync`/SSH.

So there are **no Cloudflare or site-deployment variables to configure in
Codemagic**, and none should be added. Deployment credentials for the VPS are the
owner's SSH key (`~/.ssh/qirsh_vps`), which must never enter Codemagic while no
Codemagic job deploys the site.

---

## 8. Debug-only dart-defines — never set in Codemagic

| Define | Why it must not be set |
|---|---|
| `UMP_DEBUG_FORCE_EEA` | Forces the EEA consent path for testing |
| `UMP_DEBUG_TEST_DEVICE` | Registers a test device for ad debugging |
| `REPORT_ADS_TEST_OVERRIDE` | Bypasses the report-ads gate |

All three are **release-inert by construction** — `ReportAdsDebugConfig` yields
`false` for every value of these defines in a release build. Setting them in
Codemagic would still be wrong: it signals intent the code deliberately refuses.

---

## 9. ONE-TIME CODEMAGIC SETUP

Do this **once**, when §5's outstanding items are resolved and this document's
header says READY.

### Groups and contents

**`supabase`** — attach to the **three release** workflows
(`ios-unsigned-sideload`, `ios-signed-release`, `android-release`).
**Not** `backend-and-quality-gates`, which consumes no variables.

| Variable | Secure |
|---|---|
| `SUPABASE_URL` | no |
| `SUPABASE_ANON_KEY` | **yes** |
| `LEGAL_BASE_URL` | no |
| `SENTRY_DSN` | **yes** |

**`google_play`** — attach to **`android-release` only**

| Variable | Secure |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | **yes** |
| `ANDROID_KEYSTORE_PASSWORD` | **yes** |
| `ANDROID_KEY_ALIAS` | **yes** |
| `ANDROID_KEY_PASSWORD` | **yes** |

**`admob`** *(create)* — attach to **`android-release`** and
**`ios-signed-release`** only

| Variable | Secure |
|---|---|
| all six `ADMOB_*` from §4 | **yes** |

### Must NOT be attached

- **`admob` must never be attached to `backend-and-quality-gates`.** That is the
  auto-triggered compile gate that runs on every push;
  `android_ci_compile_gate_test.dart` asserts it needs no production AdMob
  configuration, and attaching the group **fails CI**. Ordinary verification must
  never carry production monetization config.
- **`google_play` must never be attached to any iOS or quality workflow.** Signing
  material has no business in a build that cannot sign.
- `ios-unsigned-sideload` needs only `supabase`.
- **`backend-and-quality-gates` needs NO group.** It currently declares none, and
  that is deliberate: the workflow that runs automatically on every push should
  carry no credential it does not need.

### Safest order to populate

1. **`supabase`** first — nothing else is useful without a backend, and a wrong
   `SUPABASE_URL` is the most damaging single mistake here. Verify it matches
   `supabase/.temp/project-ref`.
2. **`google_play`** — then run `android-release` once and confirm the signer
   inspection passes. This proves signing before ads are involved.
3. **`admob`** last, and **only after** an `android-release` build has already
   succeeded without it. Changing one variable at a time means a failure has one
   candidate cause. Set the two **app ids** first, build, confirm the app still
   launches — a malformed app id crashes at launch, so this is the riskiest of the
   six — then add the four unit ids.
4. **Apple/ASC** whenever portal access is restored; it is independent of 1–3.

### After setup

Ads remain **OFF**. Supplying identifiers does not enable anything:
`enable_report_ads`, `enable_banner_ads` and `enable_banner_transactions_list`
stay seeded OFF, and every ad path is additionally gated on UMP consent and a
server-authoritative ad-free entitlement. Enabling is a separate decision.

---

## 10. Maintenance

Update this file whenever a new build-consumed variable appears. The audit that
produced it:

```bash
grep -oE '\$\{?[A-Z][A-Z0-9_]{2,}' codemagic.yaml | tr -d '${' | sort -u
grep -rhoE "String\.fromEnvironment\('[A-Za-z_]+'\)" app/lib | sort -u
grep -rhoE 'System\.getenv\("[A-Z_]+"\)' app/android | sort -u
grep -rhoE "Deno\.env\.get\('[A-Z_]+'\)" supabase/functions | sort -u   # NOT Codemagic
```
