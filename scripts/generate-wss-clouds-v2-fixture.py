#!/usr/bin/env python3
"""Ambient-owned night gradient/mask, no input assets; stdlib only. Repository LICENSE."""
import argparse
from pathlib import Path
import struct
import zlib

W, H = 1920, 1080
ROOT = Path(__file__).resolve().parents[1] / 'Test-Wallpaper/WSS-Clouds-v2/assets'


def png(rows):
    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data
                + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))


def assets():
    sky, mask = [], []
    for y in range(H):
        t = y / (H-1)
        shade = max(0, min(1, (0.85-t)/0.35))
        shade = round(255 * shade * shade * (3-2*shade))
        row, m = bytearray([0]), bytearray([0])
        for x in range(W):
            color = [round(8+19*t), round(15+24*t), round(30+29*t), 255]
            if y > 920 + 30 * ((x // 240) % 2):
                color = [6, 12, 19, 255]
            row.extend(color)
            m.extend([shade, shade, shade, 255])
        sky.append(row)
        mask.append(m)
    return {'background.png': png(sky), 'mask.png': png(mask)}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--check', action='store_true')
    check = p.parse_args().check
    if not check:
        ROOT.mkdir(parents=True, exist_ok=True)
    for name, content in assets().items():
        path = ROOT / name
        if check:
            if path.read_bytes() != content:
                raise SystemExit('Fixture differs: ' + str(path))
        else:
            path.write_bytes(content)
        print(('Verified ' if check else 'Generated ') + str(path))


if __name__ == '__main__':
    main()
