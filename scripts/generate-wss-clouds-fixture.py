#!/usr/bin/env python3
"""Generate project-owned visual fixture assets; Python standard library only.

All colors, curves and mask geometry are authored here for Ambient. No images,
fonts, noise assets or external files are read. Covered by the repository LICENSE.
Use --check to verify the committed PNGs without writing anything.
"""
import argparse
import math
from pathlib import Path
import struct
import zlib

WIDTH, HEIGHT = 1920, 1080
DESTINATION = Path(__file__).resolve().parents[1] / "Test-Wallpaper/WSS-Clouds-v1/assets"


def smooth(value):
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def png(rows):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
            + chunk(b"IEND", b""))


def assets():
    sky_rows, mask_rows = [], []
    # Two broad, soft silhouettes, with no detailed source texture.
    distant = [775 - 100 * math.exp(-((x - 450) / 420) ** 2)
               - 65 * math.exp(-((x - 1510) / 520) ** 2) for x in range(WIDTH)]
    near = [955 - 110 * math.exp(-((x - 1540) / 500) ** 2)
            - 35 * math.exp(-((x - 180) / 370) ** 2) for x in range(WIDTH)]
    guides = [max(0.0, 1 - min(abs(x - mark) for mark in (240, 720, 1200, 1680)) / 3)
              for x in range(WIDTH)]
    for y in range(HEIGHT):
        vertical = smooth(y / (HEIGHT - 1))
        sky = [18 + 39 * vertical, 27 + 50 * vertical, 49 + 43 * vertical]
        horizon_guide = 1.8 * math.exp(-((y - 570) / 3) ** 2)
        row = bytearray(b"\0")
        for x in range(WIDTH):
            far_blend = smooth((y - distant[x]) / 28)
            near_blend = smooth((y - near[x]) / 36)
            guide = guides[x] * 2.5 * (1 - smooth((y - 680) / 150)) + horizon_guide
            rgb = [sky[i] + guide for i in range(3)]
            rgb = [rgb[i] * (1 - far_blend) + (24, 42, 53)[i] * far_blend for i in range(3)]
            rgb = [rgb[i] * (1 - near_blend) + (12, 25, 34)[i] * near_blend for i in range(3)]
            row.extend([round(c) for c in rgb] + [255])
        sky_rows.append(bytes(row))
        # Top-left PNG/UV origin: full effect through row 430, smooth fade to
        # exact zero at row 820. All RGB channels match; alpha is always opaque.
        value = round(255 * (1 - smooth((y - 430) / 390)))
        mask_rows.append(b"\0" + bytes((value, value, value, 255)) * WIDTH)
    return {"background.png": png(sky_rows), "clouds-mask.png": png(mask_rows)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    for name, data in assets().items():
        path = DESTINATION / name
        if options.check:
            if not path.is_file() or path.read_bytes() != data:
                raise SystemExit(f"Generated asset differs: {path}")
            print(f"Verified {path} ({len(data)} bytes)")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            print(f"Generated {path} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
