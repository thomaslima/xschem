#!/usr/bin/env python3
"""Crispness and pixel checks for smoke.tcl captures. Python 3 standard library only.

  pngcheck.py sharp  shot.png x y w h       edge sharpness of a pixel rectangle
  pngcheck.py crop   shot.png x y w h zoom out.png   nearest-neighbour enlarged crop
  pngcheck.py size   shot.png
  pngcheck.py diff   a.png b.png out.png         differing pixels (red) over a dimmed a.png

sharp prints S = sum(d^2) / sum(|d|) over the luminance differences of neighbouring
pixels (rows and columns): the mean height of a step, weighted by its height. A sharp edge
changes in one step, a blurred edge in several smaller ones, so S drops when a drawing is
scaled up. Q = S(image) / S(image reduced to half size and scaled back up) tells whether
the image holds detail finer than half its resolution: a drawing made at 1x and scaled up
2x does not. Compare S of two captures of the same schematic at the same zoom; Q is a
rough absolute indication (above about 2.5 for a native 2x drawing on cmos_inv.sch).
"""
import struct
import sys
import zlib


def read(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(path + ': not a PNG file')
    pos, idat = 8, b''
    while pos < len(data):
        ln, = struct.unpack('>I', data[pos:pos + 4])
        typ, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
            if depth != 8 or interlace or ctype not in (2, 6):
                raise ValueError(path + ': only 8 bit RGB/RGBA non interlaced PNG')
            bpp = 3 if ctype == 2 else 4
        elif typ == b'IDAT':
            idat += body
    raw, stride = zlib.decompress(idat), w * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, [[tuple(r[x * bpp:x * bpp + 3]) for x in range(w)] for r in rows]


def write(path, w, h, px):
    def chunk(t, b):
        return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
    raw = b''.join(b'\x00' + bytes(c for p in row for c in p) for row in px)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def sharpness(L):
    s1 = s2 = 0.0
    for row in L:
        for i in range(len(row) - 1):
            d = abs(row[i + 1] - row[i])
            s1 += d
            s2 += d * d
    for j in range(len(L[0])):
        for i in range(len(L) - 1):
            d = abs(L[i + 1][j] - L[i][j])
            s1 += d
            s2 += d * d
    return s2 / s1 if s1 else 0.0


def half_and_back(L):
    """2x2 box reduction, then bilinear enlargement (pixel centres aligned)."""
    h, w = len(L) // 2, len(L[0]) // 2
    D = [[(L[2 * y][2 * x] + L[2 * y][2 * x + 1] + L[2 * y + 1][2 * x] + L[2 * y + 1][2 * x + 1]) / 4
          for x in range(w)] for y in range(h)]

    def g(y, x):
        return D[min(max(y, 0), h - 1)][min(max(x, 0), w - 1)]
    U = []
    for Y in range(2 * h):
        sy = (Y + 0.5) / 2 - 0.5
        y0 = int(sy // 1)
        fy = sy - y0
        row = []
        for X in range(2 * w):
            sx = (X + 0.5) / 2 - 0.5
            x0 = int(sx // 1)
            fx = sx - x0
            row.append((1 - fy) * ((1 - fx) * g(y0, x0) + fx * g(y0, x0 + 1))
                       + fy * ((1 - fx) * g(y0 + 1, x0) + fx * g(y0 + 1, x0 + 1)))
        U.append(row)
    return U


def main(a):
    if a[0] == 'size':
        w, h, _ = read(a[1])
        print('%dx%d' % (w, h))
    elif a[0] == 'sharp':
        _, _, px = read(a[1])
        x, y, w, h = map(int, a[2:6])
        L = [[0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2] for p in row[x:x + w]] for row in px[y:y + h]]
        s = sharpness(L)
        print('S=%.1f Q=%.2f' % (s, s / sharpness(half_and_back(L))))
    elif a[0] == 'crop':
        _, _, px = read(a[1])
        x, y, w, h, z = map(int, a[2:7])
        out = []
        for row in px[y:y + h]:
            r = [p for p in row[x:x + w] for _ in range(z)]
            out += [r] * z
        write(a[7], w * z, h * z, out)
    elif a[0] == 'diff':
        w, h, pa = read(a[1])
        _, _, pb = read(a[2])
        out, n, box = [], 0, [w, h, -1, -1]
        for y in range(h):
            row = []
            for x in range(w):
                if pa[y][x] != pb[y][x]:
                    n += 1
                    box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
                    row.append((255, 0, 0))
                else:
                    row.append(tuple(c // 4 for c in pa[y][x]))
            out.append(row)
        write(a[3], w, h, out)
        print('%d pixels differ, box %s' % (n, box if n else '-'))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:] or ['help'])
