#!/usr/bin/env python3
"""Fix the mechanical fallout of an l10n migration in one file.

Three passes, each driven by `flutter analyze` rather than by guessing:
  1. strip `const` from constructors that now hold a runtime lookup;
  2. drop `final l10n = ...` bindings left unused;
  3. add `const` back where the analyzer now asks for it.

Runs to a fixed point, bounded, so a file the analyzer cannot settle does not
loop forever.
"""
import re, subprocess, sys

def analyze(p):
    return subprocess.run(['flutter', 'analyze', '--no-pub', p],
                          capture_output=True, text=True).stdout

def strip_const(p):
    for _ in range(14):
        out = analyze(p)
        # `non_constant_list_element` points at the ELEMENT, not the `const [`
        # that owns it, so it needs the same upward walk as `invalid_constant`.
        bad = sorted({int(m) for m in re.findall(
            rf'{re.escape(p)}:(\d+):\d+ • (?:invalid_constant|non_constant_list_element)', out)})
        if not bad:
            return
        lines = open(p, encoding='utf-8').read().split('\n')
        changed = False
        for ln in bad:
            for i in range(ln - 1, max(ln - 16, 0), -1):
                if re.search(r'\bconst\s+[A-Z_]', lines[i]):
                    lines[i] = re.sub(r'\bconst\s+(?=[A-Z_])', '', lines[i], count=1)
                    changed = True; break
                if re.search(r'\bconst\s*\[', lines[i]):
                    lines[i] = re.sub(r'\bconst\s*(?=\[)', '', lines[i], count=1)
                    changed = True; break
        if not changed:
            return
        open(p, 'w', encoding='utf-8').write('\n'.join(lines))

def drop_unused(p):
    for _ in range(6):
        out = analyze(p)
        bad = sorted({int(m) for m in re.findall(
            rf"local variable 'l10n' isn't used.*?{re.escape(p)}:(\d+):", out)}, reverse=True)
        if not bad:
            return
        lines = open(p, encoding='utf-8').read().split('\n')
        for ln in bad:
            if re.match(r'^\s*final l10n = context\.l10n;\s*$', lines[ln - 1]):
                del lines[ln - 1]
        open(p, 'w', encoding='utf-8').write('\n'.join(lines))

def add_const(p):
    for _ in range(8):
        out = analyze(p)
        hits = sorted({(int(a), int(b)) for a, b in re.findall(
            rf'{re.escape(p)}:(\d+):(\d+) • prefer_const_constructors', out)}, reverse=True)
        if not hits:
            return
        lines = open(p, encoding='utf-8').read().split('\n')
        for ln, col in hits:
            i, c = ln - 1, col - 1
            if i < len(lines) and re.match(r'[A-Z_]', lines[i][c:c + 1] or ' '):
                lines[i] = lines[i][:c] + 'const ' + lines[i][c:]
        open(p, 'w', encoding='utf-8').write('\n'.join(lines))

if __name__ == '__main__':
    p = sys.argv[1]
    strip_const(p); drop_unused(p); add_const(p)
    print(analyze(p).strip().split('\n')[-1])
