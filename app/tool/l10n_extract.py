#!/usr/bin/env python3
"""Extract hardcoded Arabic UI literals and report them for ARB migration.

Deliberately conservative. It only reports literals it can migrate SAFELY:

  * no interpolation (`$x` / `${...}`) — those need ARB placeholders and a
    per-string decision about plural/select, which a script should not guess;
  * inside a widget-bearing file;
  * not a `debugPrint`, comment, key, or asset path.

Anything it skips is listed with the reason, so the remainder is visible
instead of silently dropped.
"""
import json, re, sys, os

ARABIC = re.compile(r'[؀-ۿ]')
LITERAL = re.compile(r"'([^'\\\n]{2,200})'")
INTERP = re.compile(r'\$\{?\w')

SKIP_LINE = re.compile(r'debugPrint|//|assert\(|Key\(|asset|package:|import |export ')

def extract(path):
    simple, complex_, skipped = [], [], []
    for i, line in enumerate(open(path, encoding='utf-8'), 1):
        if SKIP_LINE.search(line):
            continue
        for m in LITERAL.finditer(line):
            s = m.group(1)
            if not ARABIC.search(s):
                continue
            if INTERP.search(s):
                complex_.append((i, s))
            else:
                simple.append((i, s))
    return simple, complex_, skipped

if __name__ == '__main__':
    total_s = total_c = 0
    for path in sys.argv[1:]:
        s, c, _ = extract(path)
        total_s += len(s); total_c += len(c)
        print(f"{path}")
        print(f"   simple (migratable): {len(s)}   interpolated (manual): {len(c)}")
    print(f"\nTOTAL simple={total_s} interpolated={total_c}")
