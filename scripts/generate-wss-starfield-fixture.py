#!/usr/bin/env python3
"""Original synthetic Starfield acceptance fixture, repository LICENSE; stdlib only.
No personal wallpaper or third-party image data. --check never writes files.
"""
import argparse
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1] / "Test-Wallpaper/WSS-Starfield-v1"


def files():
    size = 512
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            # Schematic opaque silhouette with transparent surroundings.
            head = (x - 345) ** 2 + (y - 170) ** 2 < 42 ** 2
            body = 210 < y < 500 and abs(x - 345) < 72 - (y - 210) * 0.08
            arms = 240 < y < 420 and 62 < abs(x - 345) < 88
            row.extend([28, 32, 42, 255] if head or body or arms else [0, 0, 0, 0])
        rows.append(bytes(row))

    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))
    starfield = dict(x=0, y=0, width=3840, height=2160, count=3000, size=1.6,
                     brightness=1.2, red=1, green=1, blue=1, colorVariation=0.15,
                     seed=42, twinkleEnabled=False, twinkleIntensity=0.3,
                     twinkleSpeed=0.3, driftX=0, driftY=0)
    manifest = dict(format="wss-scene", version=1, title="WSS Starfield v1",
                    canvas=dict(width=3840, height=2160), background=[0, 0, 0],
                    layers=[dict(type="starfield", name="Static seeded sky", starfield=starfield),
                            dict(image="assets/foreground.png", composition="sourceOver",
                                 transform=dict(center=[1920, 1080], size=[3840, 2160]))])
    return {"assets/foreground.png": png,
            "scene.wss.json": (json.dumps(manifest, indent=2) + "\n").encode()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for name, data in files().items():
        target = ROOT / name
        if args.check:
            if not target.is_file() or target.read_bytes() != data:
                raise SystemExit(f"Fixture mismatch: {name}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    print("Starfield fixture verified" if args.check else "Starfield fixture generated")


if __name__ == "__main__":
    main()
