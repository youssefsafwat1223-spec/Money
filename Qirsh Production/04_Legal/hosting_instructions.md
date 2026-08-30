# Legal Hosting

## What already exists

| Artifact | Path | State |
|---|---|---|
| Privacy Policy source | `docs/legal/PRIVACY_POLICY.md` | written, fact-checked against code |
| Terms source | `docs/legal/TERMS.md` | written |
| Site generator | `tools/build_legal_site.py` | dependency-free |
| Generated site | `build/legal/` | gitignored — rebuild at publish time |

The policy is verified by `app/test/core/legal_urls_test.dart` to describe
behaviour the code actually has: consent off by default, on-device AI, and
revocation ≠ deletion. If those claims stop being true, the test fails.

## Build

```bash
python3 tools/build_legal_site.py
```

Produces directory-style output so `/privacy` and `/terms` resolve with no host
configuration:

```
build/legal/index.html
build/legal/privacy/index.html
build/legal/terms/index.html
```

An empty render **fails the build** rather than publishing a blank policy that
would satisfy a reviewer's URL check while telling the user nothing.

## Hosting — a paid domain is not required

| Option | Steps | URL |
|---|---|---|
| **Cloudflare Pages** (simplest) | Pages → Create → Direct Upload → drag `build/legal` | `https://<project>.pages.dev` |
| **Netlify Drop** | drag `build/legal` onto app.netlify.com/drop | `https://<name>.netlify.app` |
| **GitHub Pages** | push `build/legal/` contents to `gh-pages` of any public repo | `https://<user>.github.io/<repo>` |

Any of these satisfies both stores. Upload the **contents** of `build/legal/` as
the site root, not the folder itself.

## Verify

```bash
curl -sI https://<host>/privacy | head -1    # HTTP/2 200
curl -sI https://<host>/terms   | head -1    # HTTP/2 200
```

Open both in a mobile browser: styled, readable, dark-mode aware, tables scroll
rather than forcing the page sideways.

## Wiring into the build

```bash
--dart-define=LEGAL_BASE_URL=https://<host>     # no trailing slash
```

Already added to all three `codemagic.yaml` workflows — set `LEGAL_BASE_URL` in
the Codemagic `supabase` variable group. **Required for every production
build.** `legal_urls.dart` defaults to the live host, so an absent variable no
longer ships broken links — but that fallback protects *users*, not the
release. A build whose legal host is implicit cannot be reproduced or repointed
without a code change, so treat an absent or empty value as a
release-configuration defect and catch it before signing.

> **Absent or non-empty — never empty.** `String.fromEnvironment` honours
> `defaultValue` only for an *undefined* key; an empty define wins and would
> produce a hostless `/privacy` URI. Guarded in
> `app/lib/core/config/legal_urls.dart` and asserted by test.

## Verify from inside the app

Settings → **الخصوصية والبيانات** → tap both links. They must open your live
pages. If they open `mali.youssefsafwat.com`, the define did not reach the build.
