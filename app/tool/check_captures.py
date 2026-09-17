#!/usr/bin/env python3
"""Reject a capture run whose screenshots are all the same frame.

    python3 tool/check_captures.py <dir> [--min 2]

A verification run once reported 13 successful captures and wrote 13
byte-identical PNGs: the iOS launch screen. The walk had genuinely run — it
found the country chips, tapped them, advanced a step — but the device had
stopped presenting the Flutter view, so every `takeScreenshot` returned the
same splash. Nothing in the log said so. A pass that trusted its own success
line would have recorded thirteen surfaces as visually inspected with no
evidence behind any of them.

Exit non-zero when the run produced fewer than `--min` distinct images, or when
any single image accounts for more than half of them.
"""
import hashlib
import pathlib
import sys
from collections import Counter

def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args:
        print('usage: check_captures.py <dir> [--min N]')
        return 2
    minimum = 2
    if '--min' in sys.argv:
        minimum = int(sys.argv[sys.argv.index('--min') + 1])

    directory = pathlib.Path(args[0])
    shots = sorted(p for p in directory.glob('*.png'))
    if not shots:
        print(f'FAIL {directory}: no captures at all')
        return 1

    digests = Counter()
    by_digest: dict[str, list[str]] = {}
    for shot in shots:
        digest = hashlib.sha256(shot.read_bytes()).hexdigest()
        digests[digest] += 1
        by_digest.setdefault(digest, []).append(shot.name)

    distinct = len(digests)
    top_digest, top_count = digests.most_common(1)[0]
    print(f'{directory}: {len(shots)} captures, {distinct} distinct')

    failed = False
    if distinct < minimum:
        print(f'FAIL: only {distinct} distinct frame(s) — the device was very '
              f'likely not presenting the app')
        failed = True
    if top_count > len(shots) / 2 and top_count > 1:
        print(f'FAIL: one frame accounts for {top_count}/{len(shots)} captures: '
              f'{", ".join(sorted(by_digest[top_digest])[:6])}'
              f'{" …" if top_count > 6 else ""}')
        failed = True

    # Identical PAIRS are worth naming even when the run passes: two captures of
    # the same surface in different languages that match byte for byte mean the
    # screen is not localized. That is how the force-update screen was caught.
    for digest, names in by_digest.items():
        if len(names) == 2 and not failed:
            a, b = sorted(names)
            print(f'NOTE identical: {a} == {b}')
    return 1 if failed else 0

if __name__ == '__main__':
    raise SystemExit(main())
