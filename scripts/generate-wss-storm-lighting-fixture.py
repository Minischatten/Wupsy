#!/usr/bin/env python3
"""Original synthetic Wupsy 4K lighting fixture, covered by repository LICENSE.
Python stdlib only. No input images, user data or downloaded assets.
--check verifies reproducibility without writing files.
"""
import argparse
import json
from pathlib import Path
import struct
import zlib

WIDTH, HEIGHT = 3840, 2160
ROOT = Path(__file__).resolve().parents[1] / "Test-Wallpaper/WSS-Storm-Lighting-v1"


def png(rows):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def assets():
    background, foreground = [], []
    for y in range(HEIGHT):
        b, f = bytearray([0]), bytearray([0])
        for x in range(WIDTH):
            # Subtle checker detail and horizon bands make contrast visible.
            grey = 12 + y * 14 // HEIGHT + ((x // 96 + y // 96) % 2) * 3
            rgb = [grey, grey + 4, grey + 10, 255]
            if 1280 < x < 1600 and 250 < y < 580:
                value = 232 + ((x // 24 + y // 24) % 2) * 14
                rgb = [value, value, value, 255]
            if 100 < x < 1700 and HEIGHT - 180 < y < HEIGHT - 60:
                level = [0, 8, 16, 32, 64, 128, 192, 240][(x - 100) // 200]
                rgb = [level, level, level, 255]
            b.extend(rgb)
            # A deliberately schematic person, transparent outside the silhouette.
            dx = abs(x - 2540)
            head = (x - 2540) ** 2 + (y - 490) ** 2 < 145 ** 2
            torso = 630 <= y <= 1640 and dx < 285 - (y - 630) * 0.05
            arms = 760 <= y <= 1510 and 260 < dx < 350 + (y - 760) * 0.06
            legs = 1600 < y < 2080 and (80 < dx < 205)
            if head or torso or arms or legs:
                detail = ((x // 24 + y // 32) % 2) * 7
                color = [45 + detail, 50 + detail, 60 + detail, 255]
                if torso and abs(x - 2480) < 12:
                    color = [90, 94, 104, 255]
                f.extend(color)
            else:
                f.extend([0, 0, 0, 0])
        background.append(bytes(b))
        foreground.append(bytes(f))
    return {"assets/background.png": png(background), "assets/foreground.png": png(foreground)}


def manifest():
    transform = {"center": [WIDTH // 2, HEIGHT // 2], "size": [WIDTH, HEIGHT]}
    storm = dict(x=2500, y=2070, direction=0, length=1530, spread=180,
                 width=3, glow=30, brightness=1, red=0.55, green=0.7, blue=1,
                 branchDepth=2, interval=3, duration=0.16, flashes=2, flashGap=0.12, seed=1,
                 illumination=dict(enabled=True, intensity=2, red=0.8, green=0.9,
                                   blue=1, shadowLift=0.025))
    return dict(format="wss-scene", version=1, title="WSS Storm Lighting v1",
                canvas=dict(width=WIDTH, height=HEIGHT),
                layers=[dict(image="assets/background.png", transform=transform, composition="replace"),
                        dict(type="storm", name="Storm behind foreground", storm=storm),
                        dict(image="assets/foreground.png", transform=transform)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    files = assets()
    files["scene.wss.json"] = (json.dumps(manifest(), indent=2) + "\n").encode()
    for relative, data in files.items():
        path = ROOT / relative
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                raise SystemExit(f"Fixture mismatch: {relative}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    print("Storm Lighting 4K fixture verified" if args.check else f"Created {ROOT}")


if __name__ == "__main__":
    main()
