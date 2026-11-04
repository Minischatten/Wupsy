#!/usr/bin/env python3
"""Ambient-owned geometry/colors, Python stdlib only; no input images or downloads.
Covered by the repository LICENSE. --check verifies PNG reproducibility without writes.
"""
import argparse
from pathlib import Path
import struct
import zlib

WIDTH, HEIGHT = 1920, 1080
ROOT = Path(__file__).resolve().parents[1] / "Test-Wallpaper/WSS-Rain-v1/assets"


def png(rows):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
            + chunk(b"IEND", b""))


def assets():
    background, foreground = [], []
    for y in range(HEIGHT):
        b, f = bytearray([0]), bytearray([0])
        for x in range(WIDTH):
            t = y / (HEIGHT - 1)
            color = [round(12 + 13*t), round(19 + 16*t), round(30 + 20*t), 255]
            # Quiet, broad distant rectangles; no borrowed scene or image data.
            if y > 600 and (x < 270 or 1450 < x < 1800):
                color = [15, 23, 33, 255]
            b.extend(color)
            # Two obvious opaque pillars and a broad foreground rail, transparent elsewhere.
            solid = ((420 <= x < 600 and y >= 220)
                     or (1320 <= x < 1500 and y >= 220)
                     or (420 <= x < 1500 and 760 <= y < 850))
            f.extend([45, 59, 69, 255] if solid else [0, 0, 0, 0])
        background.append(b)
        foreground.append(f)
    return {"background.png": png(background), "foreground.png": png(foreground)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    check = parser.parse_args().check
    if not check:
        ROOT.mkdir(parents=True, exist_ok=True)
    for name, content in assets().items():
        path = ROOT / name
        if check:
            if path.read_bytes() != content:
                raise SystemExit("Fixture differs: " + str(path))
        else:
            path.write_bytes(content)
        print(("Verified " if check else "Generated ") + str(path))


if __name__ == "__main__":
    main()
