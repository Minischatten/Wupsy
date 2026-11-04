#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$ROOT"
./scripts/build-app.sh
STAGE=$(mktemp -d)
MOUNT=""
cleanup() {
    if [ -n "$MOUNT" ] && ! hdiutil detach "$MOUNT" -quiet; then
        echo "Could not detach $MOUNT; temporary files retained at $STAGE." >&2
        return
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir -p "$STAGE/content/.background"
ditto "$APP_PATH" "$STAGE/content/Wupsy.app"
ln -s /Applications "$STAGE/content/Applications"
cp "$APP_PATH/Contents/Resources/Wupsy.icns" "$STAGE/content/.VolumeIcon.icns"
swift scripts/dmg-background.swift "$STAGE/content/.background/background.png"
hdiutil create -quiet -fs HFS+ -volname "Wupsy $VERSION" -srcfolder "$STAGE/content" -format UDRW "$STAGE/edit.dmg"
MOUNT="$STAGE/mounted"
hdiutil attach -quiet -nobrowse -noautoopen -readwrite -noverify -mountpoint "$MOUNT" "$STAGE/edit.dmg"
LAYOUT_PYTHON="${LAYOUT_PYTHON:-python3}"
"$LAYOUT_PYTHON" scripts/dmg-layout.py "$MOUNT"
xcrun SetFile -a C "$MOUNT"
test -s "$MOUNT/.DS_Store"
sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""
DEST="$DMG_PATH"
hdiutil convert "$STAGE/edit.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$STAGE/final.dmg"
mv "$STAGE/final.dmg" "$DEST"
hdiutil verify "$DEST"
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DEST"
    codesign --verify "$DEST"
fi
# Inspect the final compressed artifact, not just the staging directory.
MOUNT="$STAGE/verified"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DEST"
"$LAYOUT_PYTHON" scripts/verify-dmg.py "$MOUNT" "$VERSION" "$BUILD_NUMBER" "$DEST"
codesign --verify --strict "$MOUNT/Wupsy.app"
hdiutil detach "$MOUNT" -quiet
MOUNT=""
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DEST")" > "$(basename "$DEST").sha256")
# Retire only obsolete, generated Wupsy DMGs in this build output directory,
# after the replacement has passed verification. Never traverse links or subfolders.
for legacy in "$DIST_DIR"/Wupsy-*-apple-silicon.dmg "$DIST_DIR"/Wupsy-*-apple-silicon.dmg.sha256; do
    if [ -f "$legacy" ] && [ ! -L "$legacy" ]; then rm -- "$legacy"; fi
done
echo "Built $DEST (not yet notarized; see DISTRIBUTION.md)"
