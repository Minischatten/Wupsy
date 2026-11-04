"""Validate the mounted distribution without launching or installing its app."""
import os
import plistlib
import sys
import subprocess
import struct
from ds_store import DSStore
from pathlib import Path
from importlib.util import spec_from_file_location, module_from_spec


def verify(root, version, build, image=None):
    if image is not None and image.name != f'Wupsy-{version}.dmg':
        raise ValueError(f'Unexpected distribution filename: {image.name}')
    spec = spec_from_file_location('verify_app', Path(__file__).with_name('verify-app.py'))
    verifier = module_from_spec(spec)
    spec.loader.exec_module(verifier)
    app = root / 'Wupsy.app'
    verifier.verify(app, version, build)
    applications = root / 'Applications'
    if not app.is_dir() or app.is_symlink():
        raise ValueError('Wupsy.app must be a real directory at the image root')
    if not applications.is_symlink() or os.readlink(applications) != '/Applications':
        raise ValueError('Applications must be a symlink to /Applications')
    expected = {'Wupsy.app', 'Applications', '.background', '.DS_Store',
                '.VolumeIcon.icns', '.fseventsd', '.Trashes', '.HFS+ Private Directory Data\r'}
    unexpected = {p.name for p in root.iterdir()} - expected
    if unexpected:
        raise ValueError(f'Unexpected disk image entries: {sorted(unexpected)}')
    bundles = [p for p in root.rglob('*.app') if p.is_dir()]
    if bundles != [app]:
        raise ValueError(f'Expected exactly one app bundle, found: {bundles}')
    for path in app.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(app.resolve()):
            raise ValueError(f'App contains an external symlink: {path}')
    executable = app / 'Contents/MacOS/Wupsy'
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError('Wupsy executable is missing or not executable')
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    for key, value in {
        'CFBundleExecutable': 'Wupsy', 'CFBundleIdentifier': 'com.wirdschonsoftware.wupsy',
        'CFBundleName': 'Wupsy', 'CFBundleDisplayName': 'Wupsy', 'CFBundleShortVersionString': version,
        'CFBundleVersion': build,
    }.items():
        if info.get(key) != value:
            raise ValueError(f'Unexpected {key}: {info.get(key)!r}')
    arch = subprocess.check_output(['xcrun', 'lipo', '-archs', str(executable)], text=True).strip()
    if arch != 'arm64':
        raise ValueError(f'Expected arm64 executable, got {arch}')
    if (root / '.VolumeIcon.icns').read_bytes() != (app / 'Contents/Resources/Wupsy.icns').read_bytes():
        raise ValueError('Volume icon must use the current Wupsy icon')
    background = root / '.background/background.png'
    header = background.read_bytes()[:24]
    if header[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', header[16:24]) != (640, 480):
        raise ValueError('Expected 640x480 WSS distribution background')
    if {p.name for p in background.parent.iterdir()} != {'background.png'}:
        raise ValueError('Unexpected background assets')
    with DSStore.open(str(root / '.DS_Store'), 'r') as layout:
        if layout['Wupsy.app']['Iloc'] != (165, 130) or layout['Applications']['Iloc'] != (475, 130):
            raise ValueError('Unexpected WSS icon positions')
        if layout['.']['bwsp']['WindowBounds'] != '{{200, 200}, {640, 550}}':
            raise ValueError('Unexpected WSS window geometry')
        options = layout['.']['icvp']
        if options['iconSize'] != 80 or options['textSize'] != 13 or options['backgroundType'] != 2:
            raise ValueError('Unexpected WSS Finder presentation')
        if b'EuroLotto' in options['backgroundImageAlias']:
            raise ValueError('Foreign product bookmark in Finder layout')
    print(f'Verified DMG: Wupsy {version} ({build}), Applications -> /Applications, '
          'arm64, shared WSS layout, one app bundle, no Setup payload')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4]) if len(sys.argv) > 4 else None)
    except (OSError, ValueError, KeyError, IndexError, struct.error, subprocess.CalledProcessError) as error:
        sys.exit(f'DMG verification failed: {error}')
