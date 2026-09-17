#!/usr/bin/env python3
"""Sample pixels from a capture and compute WCAG contrast between two of them.

    python3 tool/png_sample.py shot.png "200,1500,bg" "900,1790,fg"

Written because the eye is not evidence. The onboarding country chips were
called "white on white" from a downscaled screenshot; this said
rgb(255,255,255) on rgb(8,26,116) and turned a guess into a measurement. It
also caught the opposite mistake — two trust-badge icons that looked like
missing-glyph boxes at 620px wide and were real icons at full size.

Label a point `fg` and another `bg` and it prints their contrast ratio.

iOS Simulator captures are 16-bit RGBA. An 8-bit-only reader silently returns
garbage on them — the first version of this script reported the navy page
background as yellow — so the bit depth is read from IHDR rather than assumed.
"""
import zlib, struct, sys

def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n'
    i = 8; idat = b''
    while i < len(d):
        ln = struct.unpack('>I', d[i:i+4])[0]; typ = d[i+4:i+8]; data = d[i+8:i+8+ln]
        if typ == b'IHDR':
            w, h, bd, ct, _, _, inter = struct.unpack('>IIBBBBB', data[:13])
            assert inter == 0, 'interlaced'
        elif typ == b'IDAT': idat += data
        elif typ == b'IEND': break
        i += 12 + ln
    nch = {0:1, 2:3, 3:1, 4:2, 6:4}[ct]
    bypp = nch * (bd // 8)          # bytes per pixel — 8 for 16-bit RGBA
    stride = w * bypp
    raw = zlib.decompress(idat)
    out = bytearray(); prev = bytearray(stride); p = 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        for x in range(stride):
            a = line[x-bypp] if x >= bypp else 0
            b = prev[x]
            c = prev[x-bypp] if x >= bypp else 0
            v = line[x]
            if f == 1: line[x] = (v + a) & 255
            elif f == 2: line[x] = (v + b) & 255
            elif f == 3: line[x] = (v + (a + b) // 2) & 255
            elif f == 4:
                pp = a + b - c; pa = abs(pp-a); pb = abs(pp-b); pc = abs(pp-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (v + pr) & 255
        out += line; prev = line
    return w, h, bd, nch, bypp, bytes(out)

w, h, bd, nch, bypp, px = read_png(sys.argv[1])
step = bd // 8
def rgb(x, y):
    o = y * w * bypp + x * bypp
    return (px[o], px[o+step], px[o+2*step]) if step == 2 else (px[o], px[o+1], px[o+2])

def lum(c):
    def f(v):
        v /= 255.0
        return v/12.92 if v <= 0.04045 else ((v+0.055)/1.055) ** 2.4
    r, g, b = c
    return 0.2126*f(r) + 0.7152*f(g) + 0.0722*f(b)

def contrast(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)

print(f'# {w}x{h} bitdepth={bd} channels={nch}')
pts = {}
for spec in sys.argv[2:]:
    x, y, label = spec.split(',', 2)
    c = rgb(int(x), int(y)); pts[label] = c
    print(f'{label}: rgb{c} at ({x},{y})')
if 'fg' in pts and 'bg' in pts:
    print(f'CONTRAST fg/bg = {contrast(pts["fg"], pts["bg"]):.2f}:1')
