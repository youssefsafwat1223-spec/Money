#!/usr/bin/env python3
"""Render the public Qirsh website — Arabic at the root, English under /en/.

WHY A SECOND GENERATOR
----------------------
`build_legal_site.py` produces the standalone legal site currently deployed at
qirsh-legal.albaraai-dev.workers.dev. That site stays exactly as it is until the
qirsh.site migration completes and is verified, so it is not edited here and its
output is not replaced. This script writes a separate tree, `build/site/`.

It IMPORTS the Markdown renderer from `build_legal_site.py` rather than copying
it. `render()`/`inline()` are the legally-critical path — two copies would
eventually disagree, and the one that drifted would be serving a policy that no
longer matches the source. One implementation, several shells.

LANGUAGES
---------
Arabic is the default and lives at the root, because the app is Arabic-first.
English lives under /en/. Every page links to its counterpart and declares
`hreflang` plus a canonical, so the two are indexed as one document in two
languages rather than as duplicates.

    /            /en/            homepage
    /privacy     /en/privacy     Privacy Policy
    /terms       /en/terms       Terms of Use
    /support     /en/support     Support

THE LEGAL PAGES ARE ENGLISH IN BOTH LOCALES — deliberately. `docs/legal/*.md` is
the approved, reviewed text, and a test asserts it matches what the code actually
does. Translating it would raise "which version governs?", which is a legal
question, not a design one. The Arabic pages therefore put the Arabic shell
around the English document, say so in a line above it, and mark the body
`lang="en" dir="ltr"` so it reads correctly inside an RTL page.

NO DEPENDENCIES: standard library only. The brand font is subset and committed
(tools/site_assets/README.md) rather than subset at build time, for the same
reason the coin PNGs are pre-scaled.

LIGHT MODE ONLY. `tools/site_style.css` has no `prefers-color-scheme` rule and
there is no toggle.
"""

from __future__ import annotations

import html
import pathlib
import re
import shutil
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from build_legal_site import emit_app_ads_txt, render, stamp  # noqa: E402
from site_content import STRINGS  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "legal"
OUT = ROOT / "build" / "site"
BRAND = ROOT / "tools" / "legal_site_assets"
FONTS = ROOT / "tools" / "site_assets"
STYLE = pathlib.Path(__file__).resolve().parent / "site_style.css"

SUPPORT_EMAIL = "business@qirsh.site"
CANONICAL_ORIGIN = "https://qirsh.site"

BRAND_FILES = ("qirsh-coin-blue.png", "apple-touch-icon.png", "favicon.png")
FONT_FILES = ("IBMPlexSansArabic-Regular.woff2", "IBMPlexSansArabic-SemiBold.woff2")

LEGAL_PAGES = {
    "PRIVACY_POLICY.md": ("privacy", "privacy_title"),
    "TERMS.md": ("terms", "terms_title"),
}


def _icon(path: str) -> str:
    return ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" '
            'stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" '
            f'aria-hidden="true">{path}</svg>')


ICONS = {
    "inbox": _icon('<path d="M22 12h-6l-2 3h-4l-2-3H2"/>'
                   '<path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89'
                   'A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>'),
    "list": _icon('<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>'),
    "chart": _icon('<path d="M3 3v18h18"/><path d="M18 17V9M13 17V5M8 17v-3"/>'),
    "target": _icon('<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/>'
                    '<circle cx="12" cy="12" r="1"/>'),
    "doc": _icon('<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/>'
                 '<path d="M14 2v6h6"/><path d="M8 13h8M8 17h5"/>'),
    "wallet": _icon('<path d="M19 7V5a2 2 0 0 0-2-2H5a2 2 0 0 0 0 4h15a2 2 0 0 1 2 2v8'
                    'a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5"/><path d="M17 12h.01"/>'),
    "repeat": _icon('<path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/>'
                    '<path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/>'),
    "tick": _icon('<path d="M20 6 9 17l-5-5"/>'),
}


def base(loc: str) -> str:
    """URL prefix for a locale. Arabic is the root, so it has none."""
    return "" if loc == "ar" else "/en"


def counterpart(loc: str, path: str) -> str:
    """The same page in the other language."""
    if loc == "ar":                       # "/privacy" -> "/en/privacy"
        return "/en/" if path == "/" else "/en" + path
    tail = path[len("/en"):] or "/"       # "/en/privacy" -> "/privacy"
    return tail


def mark(size: int = 34) -> str:
    return (f'<img src="/qirsh-coin-blue.png" alt="Qirsh" width="{size}" '
            f'height="{size}">')


def shell(loc: str, title: str, body: str, *, path: str, desc: str) -> str:
    """The chrome every page shares. No admin link appears anywhere."""
    S = STRINGS[loc]
    other = S["other"]
    alt = counterpart(loc, path)
    ar_url = CANONICAL_ORIGIN + (path if loc == "ar" else alt)
    en_url = CANONICAL_ORIGIN + (alt if loc == "ar" else path)

    links = []
    for href, label in S["nav"]:
        cur = ' aria-current="page"' if href == path else ""
        links.append(f'<a href="{href}"{cur}>{label}</a>')
    nav = "\n      ".join(links)

    css = re.sub(r"/\*.*?\*/", "", STYLE.read_text(encoding="utf-8"), flags=re.S)
    css = re.sub(r"\n{3,}", "\n", css).strip()

    return f"""<!doctype html>
<html lang="{S['lang']}" dir="{S['dir']}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(desc)}">
<meta name="robots" content="index, follow">
<!-- Mitgo/Admitad ad-space ownership verification for qirsh.site. A static
     ownership proof, not a tracker: no script, no network call, no cookie, and
     no user data. Emitted from the shared head so the root homepage carries it,
     which is where the verifier looks. -->
<meta name="mitgo-verification" content="f3ac6110-e2e2-47e3-b348-7501f0f2b85f">
<meta name="color-scheme" content="light">
<meta name="theme-color" content="#F4F6FB">
<link rel="canonical" href="{CANONICAL_ORIGIN}{path}">
<link rel="alternate" hreflang="ar" href="{ar_url}">
<link rel="alternate" hreflang="en" href="{en_url}">
<link rel="alternate" hreflang="x-default" href="{ar_url}">
<link rel="icon" href="/favicon.png" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="preload" href="/IBMPlexSansArabic-Regular.woff2" as="font" type="font/woff2" crossorigin>
<style>{css}</style>
</head>
<body>
<a class="skip" href="#main">{S['skip']}</a>
<header class="site-header">
  <input type="checkbox" id="navcb" hidden>
  <div class="hdr">
    <a class="brand" href="{base(loc)}/">
      {mark()}
      <span class="brand-name">Qirsh <span class="brand-ar" lang="ar" dir="rtl">قِرش</span></span>
    </a>
    <label class="navtoggle" for="navcb" aria-label="{S['menu']}"><span></span></label>
    <nav class="nav" aria-label="{S['nav_main']}">
      {nav}
      <a class="langswitch" href="{alt}" lang="{other}" hreflang="{other}"
         title="{S['other_title']}">{S['other_label']}</a>
    </nav>
  </div>
</header>
<main id="main">
{body}
</main>
<footer class="site-footer">
  <div class="wrap">
    <div class="foot-grid">
      <div>
        <a class="brand" href="{base(loc)}/">{mark(30)}
          <span class="brand-name">Qirsh <span class="brand-ar" lang="ar" dir="rtl">قِرش</span></span></a>
        <p>{S['foot_desc']}</p>
      </div>
      <div class="foot-col">
        <h3>{S['foot_product']}</h3>
        <a href="{base(loc)}/#features">{S['foot_features']}</a>
        <a href="{base(loc)}/#privacy">{S['foot_privacy_a']}</a>
        <a href="{base(loc)}/#faq">{S['foot_faq']}</a>
      </div>
      <div class="foot-col">
        <h3>{S['foot_legal']}</h3>
        <a href="{base(loc)}/privacy">{S['foot_privacy']}</a>
        <a href="{base(loc)}/terms">{S['foot_terms']}</a>
        <a href="{base(loc)}/support">{S['foot_support']}</a>
        <a href="mailto:{SUPPORT_EMAIL}" dir="ltr">{SUPPORT_EMAIL}</a>
      </div>
    </div>
    <div class="copy">
      <span>{S['copyright']}</span>
      <span dir="ltr">{SUPPORT_EMAIL}</span>
    </div>
  </div>
</footer>
</body>
</html>
"""


def home(loc: str) -> str:
    S = STRINGS[loc]
    b = base(loc)
    rows = "".join(
        f'<div class="row"><div class="ic">{ICONS[i]}</div>'
        f'<div class="t"><b>{t}</b><span>{s}</span></div>'
        f'<div class="v {k}">{v}</div></div>'
        for i, (t, s, v, k) in zip(("wallet", "repeat", "chart"), S["shot_rows"]))
    chips = "".join(f'<span class="chip">{c}</span>' for c in S["shot_chips"])
    amount = "١٢٬٤٨٠٫٥٠" if loc == "ar" else "12,480.50"
    shot = f"""<div class="shot" role="img" aria-label="{S['shot_alt']}">
  <div class="shot-top">{mark(36)}<div class="who"><strong>{S['shot_month']}</strong>{S['shot_over']}</div></div>
  <div class="balance">
    <div class="lbl">{S['shot_bal']}</div>
    <div class="amt">{amount}</div>
    <div class="sub">{S['shot_accounts']}</div>
    <div class="chips">{chips}</div>
  </div>
  <div class="rows">{rows}</div>
</div>"""

    features = "".join(
        f'<div class="card"><div class="ic">{ICONS[i]}</div><h3>{t}</h3><p>{d}</p></div>'
        for i, t, d in S["features"])
    privacy = "".join(
        f'<li><span class="tick">{ICONS["tick"]}</span>'
        f'<span><b>{head}</b>{tail}</span></li>' for head, tail in S["privacy"])
    faqs = "".join(
        f'<details class="faq"><summary>{q}</summary><p>{a}</p></details>'
        for q, a in S["faq"])

    return f"""<section class="hero">
  <div class="wrap hero-grid">
    <div>
      <span class="eyebrow"><span class="dot"></span>{S['eyebrow']}</span>
      <h1>{S['h1_a']}<span class="accent">{S['h1_accent']}</span>{S['h1_b']}</h1>
      <p class="lede">{S['lede']}</p>
      <div class="actions">
        <a class="btn btn-primary" href="{b}/#features">{S['cta_1']}</a>
        <a class="btn btn-ghost" href="{b}/privacy">{S['cta_2']}</a>
      </div>
      <p class="note">{S['hero_note']}</p>
    </div>
    {shot}
  </div>
</section>

<section id="features" class="band">
  <div class="wrap">
    <div class="sec-head"><h2>{S['features_h']}</h2><p>{S['features_p']}</p></div>
    <div class="grid grid-3">{features}</div>
  </div>
</section>

<section id="privacy">
  <div class="wrap">
    <div class="sec-head"><h2>{S['privacy_h']}</h2><p>{S['privacy_p']}</p></div>
    <ul class="privacy-list">{privacy}</ul>
    <p class="note"><a href="{b}/privacy">{S['privacy_link']}</a></p>
  </div>
</section>

<section id="faq" class="band">
  <div class="wrap">
    <div class="sec-head"><h2>{S['faq_h']}</h2></div>
    <div class="faqwrap">{faqs}</div>
  </div>
</section>
"""


def support(loc: str) -> str:
    S = STRINGS[loc]
    return f"""<div class="wrap doc">
  <div class="doc-card">
    <h1>{S['sup_h']}</h1>
    <p>{S['sup_p']}</p>
    <div class="contact">
      <div>
        <div class="contact-lbl">{S['sup_email_l']}</div>
        <a class="mail" href="mailto:{SUPPORT_EMAIL}" dir="ltr">{SUPPORT_EMAIL}</a>
      </div>
    </div>
    <h2>{S['sup_before']}</h2>
    <p>{S['sup_before_p']}</p>
    <ul>
      <li><strong>{S['sup_i1_b']}</strong> {S['sup_i1']}</li>
      <li><strong>{S['sup_i2_b']}</strong> {S['sup_i2']}</li>
    </ul>
    <h2>{S['sup_data_h']}</h2>
    <p>{S['sup_data_p']}</p>
  </div>
</div>"""


def legal(loc: str, body: str) -> str:
    """Localised shell around the English document, which stays authoritative."""
    S = STRINGS[loc]
    note = f'<p class="legal-note">{S["legal_note"]}</p>' if S["legal_note"] else ""
    # lang/dir on the body so an English document renders correctly inside an
    # RTL page: headings, lists and tables all read left-to-right again.
    return (f'<div class="wrap doc"><div class="doc-card">{note}'
            f'<div class="legal-body" lang="en" dir="ltr">\n{body}\n</div>'
            f'</div></div>')


def main() -> int:
    if not SRC.is_dir():
        print(f"error: {SRC} not found", file=sys.stderr)
        return 1
    if not STYLE.is_file():
        print(f"error: {STYLE} not found", file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    written: list[str] = []

    for loc in ("ar", "en"):
        S = STRINGS[loc]
        b = base(loc)
        d = OUT / b.lstrip("/") if b else OUT
        d.mkdir(parents=True, exist_ok=True)
        pfx = f"{b.lstrip('/')}/" if b else ""

        (d / "index.html").write_text(
            shell(loc, S["site_title"], home(loc), path=f"{b}/", desc=S["site_desc"]),
            encoding="utf-8")
        written.append(f"{pfx}index.html")

        sup = d / "support"
        sup.mkdir(parents=True, exist_ok=True)
        (sup / "index.html").write_text(
            shell(loc, S["sup_title"], support(loc), path=f"{b}/support",
                  desc=S["sup_desc"]), encoding="utf-8")
        written.append(f"{pfx}support/index.html")

        for name, (segment, tkey) in LEGAL_PAGES.items():
            src = SRC / name
            if not src.is_file():
                print(f"error: {src} missing", file=sys.stderr)
                return 1
            md = src.read_text(encoding="utf-8")
            rendered = render(md)
            # A silently-empty legal page is worse than a build failure.
            if len(rendered) < 500:
                print(f"error: {name} rendered to {len(rendered)} bytes",
                      file=sys.stderr)
                return 1
            when = stamp(md)
            dest = d / segment
            dest.mkdir(parents=True, exist_ok=True)
            (dest / "index.html").write_text(
                shell(loc, S[tkey], legal(loc, rendered), path=f"{b}/{segment}",
                      desc=S[tkey] + (f" — {when}" if when else "")),
                encoding="utf-8")
            written.append(f"{pfx}{segment}/index.html")

    for asset in BRAND_FILES:
        f = BRAND / asset
        if not f.is_file():
            print(f"error: brand asset {f} missing", file=sys.stderr)
            return 1
        shutil.copyfile(f, OUT / asset)
        written.append(asset)

    for asset in FONT_FILES:
        f = FONTS / asset
        if not f.is_file():
            print(f"error: font {f} missing", file=sys.stderr)
            return 1
        shutil.copyfile(f, OUT / asset)
        written.append(asset)

    # app-ads.txt — AdMob seller authorisation at the DOMAIN ROOT.

    # Shared with build_legal_site.py so the two builders cannot drift.

    # THIS is the builder whose output is deployed, so this is the copy

    # that actually reaches https://qirsh.site/app-ads.txt.

    try:

        _ads = emit_app_ads_txt(OUT)

    except ValueError as exc:

        print(f"error: {exc}", file=sys.stderr)

        return 1

    if _ads:

        written.append(_ads)


    print(f"wrote {len(written)} files to {OUT}:")
    for w in written:
        print(f"  {w}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
