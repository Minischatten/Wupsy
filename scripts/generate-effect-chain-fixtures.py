#!/usr/bin/env python3
"""Own procedural effect-stack visual projects; no imported or private resources.

Run from any directory. Creates a fresh dist/VisualTests/19742 directory;
never overwrites an existing diagnostic run. Output is local generated test data.
"""
import json
import math
from pathlib import Path
import struct
import zlib


def png(width, height, pixel):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + bytes(v for x in range(width) for v in pixel(x, y)) for y in range(height))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    root = Path(__file__).resolve().parents[1] / 'dist' / 'VisualTests' / '19742'
    root.mkdir(parents=True, exist_ok=False)
    width, height = 512, 288
    def pixel(x, y):
        grid = ((x // 24 + y // 24) % 2) * 75
        edge = min(x, y, width - 1 - x, height - 1 - y)
        return (int(55 + 100 * x / width), 45 + grid, int(80 + 130 * y / height), min(255, edge * 16))
    image = png(width, height, pixel)
    mask = png(64, 64, lambda x, y: (int(255 * x / 63), 0, 0, 255))
    fields = []
    for reverse in [False, True]:
        vectors = b''.join(struct.pack('<ee', (-1 if reverse else 1) * (0.3 + y / 25),
                                      0.4 * math.sin(x / 3)) for y in range(16) for x in range(16))
        coverage = bytes(80 + (x * 7 + y * 5) % 175 for y in range(16) for x in range(16))
        fields.append(b'WSSVF16\0' + struct.pack('<6I', 1, 16, 16, 16, 16, 0) + vectors + coverage)
    def flow(suffix):
        return {'type': 'flow', 'flowMap': {'format': 'wss-vector-field-f16', 'version': 1,
                'asset': f'assets/field-{suffix}.wssvf'}, 'speed': 45, 'strength': 18}
    ripple = {'type': 'ripple', 'amplitude': 9, 'wavelength': 75, 'stretch': 1.4, 'direction': 115,
              'travelSpeed': 26, 'evolutionRate': 0.2, 'seed': 19742, 'mask': 'assets/mask.png'}
    clouds = {'type': 'clouds', 'velocity': [18, -6], 'scale': 110, 'intensity': 0.6,
              'density': 0.5, 'seed': 42691, 'mask': 'assets/mask.png'}
    cases = {'01-Ripple-Flow': [ripple, flow('A')], '02-Flow-Flow': [flow('A'), flow('B')],
             '03-Clouds-Ripple': [clouds, ripple], '04-Ripple-Clouds': [ripple, clouds],
             '05-Four-Stages': [flow('A'), ripple, flow('B'), clouds],
             '06-Flow-Ripple-Comparison': [flow('A'), ripple]}
    for name, effects in cases.items():
        project = root / name
        assets = project / 'assets'
        assets.mkdir(parents=True)
        (assets / 'base.png').write_bytes(image)
        (assets / 'mask.png').write_bytes(mask)
        for suffix, field in zip(['A', 'B'], fields):
            (assets / f'field-{suffix}.wssvf').write_bytes(field)
        manifest = {'format': 'wss-scene', 'version': 1, 'title': f'Phase 9C {name}',
                    'canvas': {'width': width, 'height': height}, 'background': [0.035, 0.045, 0.07],
                    'layers': [{'image': 'assets/base.png', 'composition': 'sourceOver',
                                'transform': {'center': [width / 2, height / 2], 'size': [width, height]},
                                'effects': effects}]}
        (project / 'scene.wss.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (root / 'README.md').write_text(
        'Native Effektstacks – synthetische Vergleichsfälle\n\n'
        'Eigene prozedurale, reproduzierbare PNG-/Vektorfeldressourcen; keine privaten Assets.\n'
        'Pro Projekt scene.wss.json in Wupsy öffnen/importieren. Preview und Desktop vergleichen.\n'
        '01 gegen 06 und 03 gegen 04: unterschiedliche Reihenfolge. 02: getrennte Felder. '
        '05: vier Stages mit A/B-Ping-Pong. Transparente Ränder und rote Gradientmaske beachten.\n'
        'Mindestens einen Fall in Standard/HiDPI prüfen; bestehende native Szenen unverändert lassen.\n'
        'Generierte Vergleichsdateien bleiben lokal unter dist/ und gehören nicht in den Quellsnapshot.\n')
    print(root)


if __name__ == '__main__':
    main()
