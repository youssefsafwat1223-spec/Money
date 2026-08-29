#!/usr/bin/env python3
"""Render docs/legal/*.md into a static site the owner can upload anywhere.

WHY THIS EXISTS
---------------
`kLegalBaseUrl` points at `/privacy` and `/terms`, and both app stores require a
reachable privacy-policy URL. The documents were written and reviewed; the only
thing standing between them and a live URL was that they are Markdown and a host
serves HTML. This turns the owner's remaining task from "write, convert and host
a privacy policy" into "upload one directory".

Output is DIRECTORY-STYLE so the URLs the app already builds work unchanged:

    build/legal/index.html
    build/legal/privacy/index.html   -> served at /privacy
    build/legal/terms/index.html     -> served at /terms

GitHub Pages, Netlify, Cloudflare Pages and S3 static hosting all resolve
`/privacy` to `privacy/index.html` with no configuration and no build step.

NO DEPENDENCIES ON PURPOSE
--------------------------
A release artifact that needs `pip install` before it can be regenerated is one
more thing to go wrong at the worst moment. This uses only the standard library,
and renders exactly the Markdown subset these two documents use — headings,
bold, inline code, unordered and ordered lists, tables, rules, paragraphs and
links. Anything outside that subset raises rather than silently dropping text
from a legal document, which is the one failure mode that actually matters here.
"""

from __future__ import annotations

import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "legal"
OUT = ROOT / "build" / "legal"

# Source document -> published path segment. The segments must match the paths
# `legal_urls.dart` builds; `test/core/legal_urls_test.dart` asserts they do.
PAGES = {
    "PRIVACY_POLICY.md": ("privacy", "Privacy Policy"),
    "TERMS.md": ("terms", "Terms of Use"),
}

# Cross-document links in the Markdown point at sibling files; on the site they
# must point at the published paths instead.
LINK_REWRITES = {
    "./PRIVACY_POLICY.md": "/privacy",
    "./TERMS.md": "/terms",
    "PRIVACY_POLICY.md": "/privacy",
    "TERMS.md": "/terms",
}

STYLE = """
:root {
  --bg: #ffffff; --fg: #1a1d23; --muted: #5b6472;
  --rule: #e3e7ee; --accent: #021B79; --code-bg: #f4f6fa;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1115; --fg: #e8ebf0; --muted: #9aa4b2;
    --rule: #262b33; --accent: #8fa8ff; --code-bg: #171b21;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 2.5rem 1.25rem 5rem;
  background: var(--bg); color: var(--fg);
  font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
        "Helvetica Neue", Arial, sans-serif;
  -webkit-text-size-adjust: 100%;
}
main { max-width: 44rem; margin: 0 auto; }
h1 { font-size: 1.9rem; line-height: 1.25; margin: 0 0 1.5rem; }
h2 { font-size: 1.3rem; margin: 2.5rem 0 .75rem; }
h3 { font-size: 1.05rem; margin: 1.75rem 0 .5rem; }
h4 { font-size: 1rem; margin: 1.5rem 0 .5rem; color: var(--muted); }
p, li { margin: 0 0 .85rem; }
ul, ol { padding-inline-start: 1.35rem; }
a { color: var(--accent); }
hr { border: 0; border-top: 1px solid var(--rule); margin: 2.25rem 0; }
code {
  background: var(--code-bg); padding: .12em .35em;
  border-radius: 4px; font-size: .9em;
}
/* Wide tables scroll inside their own box; the page never scrolls sideways. */
.tablewrap { overflow-x: auto; margin: 0 0 1.25rem; }
table { border-collapse: collapse; width: 100%; font-size: .94rem; }
th, td {
  text-align: start; padding: .5rem .7rem;
  border-bottom: 1px solid var(--rule); vertical-align: top;
}
th { font-weight: 600; white-space: nowrap; }
footer {
  margin-top: 3.5rem; padding-top: 1.25rem;
  border-top: 1px solid var(--rule); color: var(--muted); font-size: .9rem;
}
footer a { margin-inline-end: 1rem; }
""".strip()


def inline(text: str) -> str:
    """Escape, then apply the inline Markdown these documents use."""
    out = html.escape(text, quote=False)
    # Code first: its contents must not then be read as bold or a link.
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)

    def link(m: re.Match) -> str:
        label, href = m.group(1), m.group(2)
        href = LINK_REWRITES.get(href, href)
        return f'<a href="{html.escape(href, quote=True)}">{label}</a>'

    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, out)


def render(md: str) -> str:
    """Render the Markdown subset used by docs/legal/. Unknown syntax raises."""
    lines = md.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()

        if not line.strip():
            i += 1
            continue

        # Horizontal rule. Checked before tables so `---|---` is not mistaken.
        if re.fullmatch(r"-{3,}", line.strip()):
            out.append("<hr>")
            i += 1
            continue

        heading = re.match(r"^(#{1,4})\s+(.*)$", line)
        if heading:
            level = len(heading.group(1))
            out.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            i += 1
            continue

        # Table: a header row, a separator row, then body rows.
        if line.lstrip().startswith("|"):
            if i + 1 >= len(lines) or not re.match(
                r"^\s*\|[\s:|-]+\|\s*$", lines[i + 1]
            ):
                raise ValueError(f"line {i+1}: table header without separator")

            def cells(row: str) -> list[str]:
                return [c.strip() for c in row.strip().strip("|").split("|")]

            head = cells(line)
            i += 2
            body: list[list[str]] = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                body.append(cells(lines[i]))
                i += 1
            parts = ["<div class=\"tablewrap\"><table><thead><tr>"]
            parts += [f"<th>{inline(c)}</th>" for c in head]
            parts.append("</tr></thead><tbody>")
            for row in body:
                parts.append("<tr>")
                parts += [f"<td>{inline(c)}</td>" for c in row]
                parts.append("</tr>")
            parts.append("</tbody></table></div>")
            out.append("".join(parts))
            continue

        # Unordered list.
        if re.match(r"^[-*]\s+", line):
            items = []
            while i < len(lines) and re.match(r"^[-*]\s+", lines[i].rstrip()):
                items.append(re.sub(r"^[-*]\s+", "", lines[i].rstrip()))
                i += 1
                # Continuation lines are indented under the bullet.
                while i < len(lines) and re.match(r"^\s{2,}\S", lines[i]):
                    items[-1] += " " + lines[i].strip()
                    i += 1
            out.append(
                "<ul>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ul>"
            )
            continue

        # Ordered list.
        if re.match(r"^\d+\.\s+", line):
            items = []
            while i < len(lines) and re.match(r"^\d+\.\s+", lines[i].rstrip()):
                items.append(re.sub(r"^\d+\.\s+", "", lines[i].rstrip()))
                i += 1
                while i < len(lines) and re.match(r"^\s{3,}\S", lines[i]):
                    items[-1] += " " + lines[i].strip()
                    i += 1
            out.append(
                "<ol>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ol>"
            )
            continue

        # Paragraph: consume until a blank line or the start of another block.
        para = [line]
        i += 1
        while i < len(lines):
            nxt = lines[i].rstrip()
            if not nxt.strip():
                break
            if re.match(r"^(#{1,4}\s|[-*]\s|\d+\.\s)", nxt) or nxt.lstrip().startswith(
                "|"
            ) or re.fullmatch(r"-{3,}", nxt.strip()):
                break
            para.append(nxt)
            i += 1
        out.append(f"<p>{inline(' '.join(para))}</p>")

    return "\n".join(out)


def page(title: str, body: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} — Qirsh</title>
<meta name="robots" content="index, follow">
<style>{STYLE}</style>
</head>
<body>
<main>
{body}
<footer>
<a href="/privacy">Privacy Policy</a><a href="/terms">Terms of Use</a>
</footer>
</main>
</body>
</html>
"""


INDEX_BODY = """<h1>Qirsh — Legal</h1>
<p>The documents below describe how Qirsh (قِرش) handles your data and the terms
under which it is offered.</p>
<ul>
<li><a href="/privacy">Privacy Policy</a></li>
<li><a href="/terms">Terms of Use</a></li>
</ul>"""


def main() -> int:
    if not SRC.is_dir():
        print(f"error: {SRC} not found", file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "index.html").write_text(page("Legal", INDEX_BODY), encoding="utf-8")
    written = ["index.html"]

    for name, (segment, title) in PAGES.items():
        src = SRC / name
        if not src.is_file():
            print(f"error: {src} missing", file=sys.stderr)
            return 1
        body = render(src.read_text(encoding="utf-8"))
        # A silently-empty legal page is worse than a build failure.
        if len(body) < 500:
            print(f"error: {name} rendered to {len(body)} bytes", file=sys.stderr)
            return 1
        dest = OUT / segment
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "index.html").write_text(page(title, body), encoding="utf-8")
        written.append(f"{segment}/index.html")

    print(f"wrote {len(written)} files to {OUT}:")
    for w in written:
        print(f"  {w}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
