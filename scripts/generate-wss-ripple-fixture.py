#!/usr/bin/env python3
"""Own diagnostic artwork; stdlib only, no input media. Repository LICENSE.
--check compares reproducible PNGs without writing.
"""
import argparse
import math
from pathlib import Path
import struct
import zlib

WIDTH, HEIGHT = 960, 540
ROOT = Path(__file__).resolve().parents[1] / 'Test-Wallpaper/WSS-Ripple-v1/assets'


def png(rows):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))


def assets():
    background, mask = [], []
    for y in range(HEIGHT):
        b, m = bytearray([0]), bytearray([0])
        for x in range(WIDTH):
            checker = ((x // 24) + (y // 24)) % 2
            color = [24 + 8*checker, 92 + 12*checker, 125 + 16*checker, 255]
            if x % 48 < 2 or y % 36 < 2:
                color = [125, 207, 215, 255]
            if (x % 96 - 48)**2 + (y % 108 - 54)**2 < 20:
                color = [240, 212, 100, 255]
            # Own irregular ellipse, with textured stone interior and an obvious rim.
            distance = math.hypot((x-680)/170, (y-355)/112)
            if distance < 1:
                grain = (x*17 + y*29 + (x*y) % 41) % 24
                color = [126+grain, 112+grain, 90+grain, 255]
                if distance > 0.96:
                    color = [222, 199, 151, 255]
            # Full water coverage; a 24px ramp extends into the stone edge.
            value = max(0, min(1, (distance - 0.79)/0.21))
            if y < 100:
                value *= 0 if x < 450 else max(0, min(1, (y-65)/35))
            if x < 40 or x >= 930 or y >= 510:
                value = 0
            level = round(value*255)
            b.extend(color)
            m.extend([level, level, level, 255])
        background.append(b)
        mask.append(m)
    return {'background.png': png(background), 'mask.png': png(mask)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    check = parser.parse_args().check
    if not check:
        ROOT.mkdir(parents=True, exist_ok=True)
    for name, data in assets().items():
        path = ROOT / name
        if check:
            if path.read_bytes() != data:
                raise SystemExit('Fixture differs: ' + str(path))
        else:
            path.write_bytes(data)
        print(('Verified ' if check else 'Generated ') + str(path))


if __name__ == '__main__':
    main()
