# Where the legal documents live

Not archived — **canonical and active**:

| Artifact | Path |
|---|---|
| Privacy Policy source | `docs/legal/PRIVACY_POLICY.md` |
| Terms source | `docs/legal/TERMS.md` |
| Site generator | `tools/build_legal_site.py` |
| Generated site | `build/legal/` (gitignored; rebuild at publish time) |

They stay in `docs/legal/` because `app/test/core/legal_urls_test.dart` and
`tools/build_legal_site.py` both resolve those exact paths. Moving them would
break the test and the generator.

Hosting instructions: [`../04_Legal/hosting_instructions.md`](../04_Legal/hosting_instructions.md).
