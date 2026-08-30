# Legal site brand assets

Pre-scaled copies of the canonical Qirsh coin mark, committed so that
`tools/build_legal_site.py` stays standard-library-only. Resizing at build time
would add a Pillow dependency to a release artifact for files that never change.

Canonical source (do not substitute — `AppAssets.getCoin()` selects between
these two by theme, and `AppAssets.getLogo()` returns `qirsh_logo_full.png`):

| Output | Source | Size |
|---|---|---|
| `qirsh-coin-gold.png` | `app/assets/qirsh/qirsh_coin_gold.png` | 96×96 |
| `qirsh-coin-blue.png` | `app/assets/qirsh/qirsh_coin.png` | 96×96 |
| `apple-touch-icon.png` | `app/assets/qirsh/qirsh_coin.png` | 180×180 |
| `favicon.png` | `app/assets/qirsh/qirsh_coin.png` | 48×48 |

`app/assets/brand/` is NOT the source: it is an unreferenced duplicate of
`app/assets/logo/`, and neither carries the current Qirsh mark.

Regenerate (needs Pillow; not required for the normal build):

```bash
python3 - <<'PY'
from PIL import Image; import pathlib
src = pathlib.Path('app/assets/qirsh'); out = pathlib.Path('tools/legal_site_assets')
for s, d, n in [('qirsh_coin_gold.png','qirsh-coin-gold.png',96),
                ('qirsh_coin.png','qirsh-coin-blue.png',96),
                ('qirsh_coin.png','apple-touch-icon.png',180),
                ('qirsh_coin.png','favicon.png',48)]:
    Image.open(src/s).convert('RGBA').resize((n,n), Image.LANCZOS).save(out/d, optimize=True)
PY
```
