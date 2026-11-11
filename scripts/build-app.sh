#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$ROOT"
if ! SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)" || [ ! -d "$SDK_PATH" ]; then
    echo "Cannot resolve the selected macOS SDK path. Check xcode-select." >&2
    exit 1
fi
if ! SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)" || [[ ! "$SDK_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Cannot resolve the selected macOS SDK version. Check xcode-select." >&2
    exit 1
fi
# Swift's -sdk alone can leave Clang's link step using the deployment target
# as its SDK marker. Supply both versions at link time, never patch the binary.
BUILD_ARGS=(--build-system swiftbuild -c release --arch arm64 --sdk "$SDK_PATH"
    -Xlinker -platform_version -Xlinker macos
    -Xlinker "$MACOS_DEPLOYMENT_TARGET" -Xlinker "$SDK_VERSION")
swift build "${BUILD_ARGS[@]}" --jobs "${BUILD_JOBS:-2}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
# Assemble in a new directory so stale resources cannot enter the signed bundle.
APP_WORK="$(mktemp -d "$DIST_DIR/.wupsy-app.XXXXXX")"
trap 'rm -rf "$APP_WORK"' EXIT
BUNDLE_PATH="$APP_WORK/Wupsy.app"
mkdir -p "$BUNDLE_PATH/Contents/MacOS" "$BUNDLE_PATH/Contents/Resources"
cp "$BIN_DIR/Wupsy" "$BUNDLE_PATH/Contents/MacOS/Wupsy"
# SwiftPM compiles the string catalog; copy its actual resource bundle rather
# than catalog sources or an assumed cache path. Removed import templates are
# excluded even when an incremental SwiftPM cache still contains them.
RESOURCE_BUNDLE="$BIN_DIR/Wupsy_Wupsy.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi
rsync -a --exclude=.DS_Store --exclude=NativeProjects "$RESOURCE_BUNDLE" "$BUNDLE_PATH/Contents/Resources/"
# Validate the actual bundled executable before signing or replacing the old app.
BINARY="$BUNDLE_PATH/Contents/MacOS/Wupsy"
if [ "$(xcrun lipo -archs "$BINARY")" != "arm64" ]; then
    echo "Expected an arm64 executable: $BINARY" >&2
    exit 1
fi
BUILD_INFO="$(xcrun vtool -show-build "$BINARY")"
if ! awk -v minimum="$MACOS_DEPLOYMENT_TARGET" -v sdk="$SDK_VERSION" '
    function version(v, parts) {
        split(v, parts, ".")
        return sprintf("%d.%d.%d", parts[1], parts[2], parts[3])
    }
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { commands++ }
    $1 == "platform" && $2 == "MACOS" { platforms++ }
    $1 == "minos" && version($2) == version(minimum) { minimums++ }
    $1 == "sdk" && version($2) == version(sdk) { sdks++ }
    END { exit !(commands == 1 && platforms == 1 && minimums == 1 && sdks == 1) }
' <<< "$BUILD_INFO"; then
    echo "Unexpected Mach-O build version; expected macOS minimum $MACOS_DEPLOYMENT_TARGET / SDK $SDK_VERSION:" >&2
    echo "$BUILD_INFO" >&2
    exit 1
fi
ICON_WORK="$APP_WORK"
swift scripts/make-icon.swift "$ICON_WORK/Wupsy.iconset"
iconutil -c icns "$ICON_WORK/Wupsy.iconset" -o "$BUNDLE_PATH/Contents/Resources/Wupsy.icns"
cp LICENSE THIRD-PARTY-NOTICES.md BRANDING.md BRANDING.en.md "$BUNDLE_PATH/Contents/Resources/"
mkdir -p "$BUNDLE_PATH/Contents/Resources/Brand"
cp Brand/LICENSE "$BUNDLE_PATH/Contents/Resources/Brand/LICENSE"
cp Brand/Wupsy-MenuBar-Icon-v1.png "$BUNDLE_PATH/Contents/Resources/"
cat > "$BUNDLE_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Wupsy</string>
<key>CFBundleIdentifier</key><string>com.wirdschonsoftware.wupsy</string>
<key>CFBundleName</key><string>Wupsy</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
<key>CFBundleDisplayName</key><string>Wupsy</string>
<key>CFBundleIconFile</key><string>Wupsy.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>$MACOS_DEPLOYMENT_TARGET</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.wirdschonsoftware.wupsy.playlist-entry</string>
<key>UTTypeDescription</key><string>Wupsy playlist entry</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict><dict>
<key>UTTypeIdentifier</key><string>com.wirdschonsoftware.wupsy.library-backup</string>
<key>UTTypeDescription</key><string>Wupsy Wallpaper Library Backup</string>
<key>UTTypeConformsTo</key><array><string>public.zip-archive</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>wssbackup</string></array></dict>
</dict></array>
</dict></plist>
PLIST
python3 scripts/verify-app.py "$BUNDLE_PATH" "$VERSION" "$BUILD_NUMBER"
# Argument-domain language overrides are process-local; no user preferences or
# application data are written. The verifier exits before normal startup.
"$BINARY" --verify-localization en -AppleLanguages '(en)'
"$BINARY" --verify-localization de -AppleLanguages '(de)'
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$BUNDLE_PATH"
else
    codesign --force --sign - "$BUNDLE_PATH"
fi
codesign --verify --strict "$BUNDLE_PATH"
if [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; then rm -rf "$APP_PATH"; fi
mv "$BUNDLE_PATH" "$APP_PATH"
echo "Built $APP_PATH (version $VERSION, build $BUILD_NUMBER, source $(git rev-parse --short HEAD))"
