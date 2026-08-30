# Site fonts

Subset copies of **IBM Plex Sans Arabic** — the app's primary family
(`app/pubspec.yaml`), and the same family the PDF report renderer draws with.

Committed rather than generated at build time so `tools/build_site.py` stays
standard-library-only. Subsetting needs `fonttools`; the build must not.

| Output | Source | Size |
|---|---|---|
| `IBMPlexSansArabic-Regular.woff2` | `app/assets/fonts/IBMPlexSansArabic-Regular.ttf` | 32 KB (was 230 KB) |
| `IBMPlexSansArabic-SemiBold.woff2` | `app/assets/fonts/IBMPlexSansArabic-SemiBold.ttf` | 34 KB (was 239 KB) |

66 KB for both weights — **13.9%** of the raw TTFs. That is what made using the
real brand face affordable on a marketing site instead of falling back to a
system stack.

Licence: SIL OFL 1.1 — `app/assets/fonts/IBMPlexSansArabic-OFL.txt`. Subsetting
and format conversion are permitted; the licence travels with the derivative.

Regenerate (needs `pip install "fonttools[woff]" brotli`):

```bash
U='U+0020-007E,U+00A0,U+00AB,U+00BB,U+060C,U+061B,U+061F,U+0621-063A,U+0640-0652,U+0660-0669,U+066A-066D,U+0670-0673,U+06D6-06ED,U+FE70-FEFC,U+2000-206F,U+2190-21BB,U+2212,U+2E2E'
for w in Regular SemiBold; do
  pyftsubset "app/assets/fonts/IBMPlexSansArabic-$w.ttf" \
    --unicodes="$U" --layout-features='*' --flavor=woff2 \
    --output-file="tools/site_assets/IBMPlexSansArabic-$w.woff2"
done
```

`--layout-features='*'` is not optional: Arabic needs `init`/`medi`/`fina`/`liga`
to join letters. Dropping them yields disconnected letterforms that look like a
rendering bug.
