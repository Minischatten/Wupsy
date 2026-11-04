#!/bin/bash
# Shared build paths and release metadata.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
# Keep in sync with Package.swift platforms; this is not the build SDK version.
MACOS_DEPLOYMENT_TARGET="14.0"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_PATH="$DIST_DIR/Wupsy.app"
DMG_PATH="$DIST_DIR/Wupsy-${VERSION}.dmg"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain a semantic version, such as 0.5.0." >&2
    exit 1
fi
if [ -n "${SIGNING_IDENTITY:-}" ] && [[ "$SIGNING_IDENTITY" != 'Developer ID Application:'* ]]; then
    echo "SIGNING_IDENTITY must be a Developer ID Application identity. Unset it for an ad-hoc development build." >&2
    exit 1
fi
mkdir -p "$DIST_DIR"
