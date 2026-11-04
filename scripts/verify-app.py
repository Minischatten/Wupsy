"""Validate the product identity of a built app without launching it."""
import os
import plistlib
import sys
from pathlib import Path


def verify(app, version, build):
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    expected = {
        'CFBundleExecutable': 'Wupsy',
        'CFBundleIdentifier': 'com.wirdschonsoftware.wupsy',
        'CFBundleName': 'Wupsy', 'CFBundleDisplayName': 'Wupsy',
        'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'de'],
        'CFBundleIconFile': 'Wupsy.icns', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': version, 'CFBundleVersion': build,
        'LSMinimumSystemVersion': '14.0', 'LSUIElement': True,
        'NSHighResolutionCapable': True,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f'Unexpected {key}: {info.get(key)!r}')
    identifiers = {item['UTTypeIdentifier'] for item in info['UTExportedTypeDeclarations']}
    if identifiers != {'com.wirdschonsoftware.wupsy.playlist-entry',
                       'com.wirdschonsoftware.wupsy.library-backup'}:
        raise ValueError(f'Unexpected exported types: {identifiers}')
    executable = app / 'Contents/MacOS/Wupsy'
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError('Wupsy executable is missing')
    for name in ['Wupsy.icns', 'LICENSE', 'THIRD-PARTY-NOTICES.md',
                 'BRANDING.md', 'BRANDING.en.md', 'Brand/LICENSE']:
        if not (app / 'Contents/Resources' / name).exists():
            raise ValueError(f'Missing resource: {name}')
    # Bundle.module must resolve inside the distributable app.
    resource_bundle = app / 'Contents/Resources/Wupsy_Wupsy.bundle'
    if not resource_bundle.is_dir():
        raise ValueError('Missing SwiftPM resource bundle')
    for language in ['en', 'de']:
        if not list(resource_bundle.rglob(f'{language}.lproj/Localizable.strings')):
            raise ValueError(f'Missing {language} localization')
    for path in app.rglob('*'):
        if 'ambient' in path.name.lower() or path.suffix == '.app' or path.name == 'NativeProjects':
            raise ValueError(f'Unexpected product resource: {path}')
        if path.name == '.DS_Store':
            raise ValueError(f'Unexpected Finder metadata: {path}')
    print(f'Verified app: Wupsy {version} ({build})')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
    except (OSError, ValueError, KeyError, IndexError) as error:
        sys.exit(f'App verification failed: {error}')
