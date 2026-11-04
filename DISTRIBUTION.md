# Distribution and signing

The DMG layout tools require Python 3.10 or newer (including the interpreter used to create `.venv`).

`VERSION` is the single release-version source. `scripts/config.sh` defines paths and an optional `BUILD_NUMBER`. Builds write only to `dist/` unless `DIST_DIR` is explicitly supplied. Wupsy uses `com.wirdschonsoftware.wupsy`, its own Application Support and cache roots, and a fresh preference domain. There is no Ambient data migration.

## Development builds

```sh
./scripts/build-app.sh
LAYOUT_PYTHON="$PWD/.venv/bin/python" ./scripts/build-dmg.sh
```

Without `SIGNING_IDENTITY`, the app receives an ad-hoc signature. These signatures do **not** establish Apple developer identity or notarization. The initial public preview uses this development-signing path. SHA-256 checksums detect accidental changes but do not replace Apple signing.

The DMG contains `Wupsy.app` and an `Applications` symlink to `/Applications`, with the shared WSS layout: 640×550 Finder window, 80-pixel icons at (165,130) and (475,130), a light installation area and a black WSS branding area. The generated 640×480 background uses the unchanged `Brand/WSS_Logo.png`; the volume icon uses the current Wupsy app icon. Copy the app using Finder, wait for completion, eject the image, and launch the copied app from Applications. No setup app, custom copy process, Finder automation, or privileged helper is used.

`build-app.sh` assembles a fresh bundle from the current Release executable before signing. `build-dmg.sh` mounts the final compressed image read-only, verifies its structure and embedded app signature, and detaches it normally before reporting success. It does not install or launch Wupsy. The build output reports version, build number, and source HEAD; local uncommitted changes are included in a local build.

Wallpaper files are never included. New wallpaper imports are copied into the user’s managed Application Support library; historical external entries retain their existing paths.

## Apple-trusted releases

Apple Developer ID and notarization require Apple Developer Program membership. Open-source status alone does not provide a fee waiver. Qualifying organizations may apply through Apple's program.

- [Membership comparison](https://developer.apple.com/support/compare-memberships/)
- [Developer ID](https://developer.apple.com/developer-id/)
- [Fee-waiver eligibility](https://developer.apple.com/help/account/membership/fee-waivers)

After the account holder installs a Developer ID Application certificate and private key in Keychain:

```sh
export SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export LAYOUT_PYTHON="$PWD/.venv/bin/python"
./scripts/build-dmg.sh
```

This signs Wupsy first and the DMG last, with hardened runtime on executables and secure timestamps. It verifies each signature. Signatures must be tested with actual credentials before describing a release as trusted.

Store notarization credentials directly in Keychain, outside the repository:

```sh
xcrun notarytool store-credentials WupsyNotary
export NOTARY_PROFILE=WupsyNotary
./scripts/notarize.sh
```

The script rejects ad-hoc artifacts, submits the DMG, requires an **Accepted** result, staples and validates its ticket, assesses the DMG with Gatekeeper, and regenerates the checksum. If rejected, use the submission ID with `notarytool log` and resolve the reported issue. The Developer ID/notarization path has not been exercised without an enrolled account and certificate.

Do not commit certificates, private keys, provisioning files, Keychain databases, tokens, or passwords. Do not upload signing material to an issue. Test an actual quarantined download on a separate Mac before publishing a trusted release, including copying the app, ejecting the image before first launch, and opening the copied app. The DMG ticket is stapled; individual extracted app bundles are not separately stapled by this script.

## GitHub releases

CI validates formatting, tests and arm64 app packaging without secrets. It uploads development build artifacts only; it does not automatically label them trusted or publish them as releases.

A maintainer builds and verifies a DMG locally, then publishes it and its `.sha256` file. Preview releases must say they are ad-hoc signed and not notarized. Use the repository's exact source commit and `VERSION`. Verify that no personal wallpaper assets or local paths enter the archive.

See [third-party notices](THIRD-PARTY-NOTICES.md) for current attribution and historical provenance limits. No personal wallpaper media is included. Branding reuse is separately described in [German](BRANDING.md) and [English](BRANDING.en.md), subject to existing rights.

## Distribution branding

The build is self-contained. scripts/make-icon.swift converts Brand/Wupsy-Logo-v2.png into the app icon; build-app.sh copies Brand/Wupsy-MenuBar-Icon-v1.png as the template menu icon. scripts/dmg-background.swift uses Brand/WSS_Logo.png for the disk-image background. No sibling project checkout is read.

The public filename is Wupsy-<Version>.dmg (and .dmg.sha256); arm64 is a property of the executable. Successful verification removes obsolete generated architecture-suffixed files only from the configured output directory, excluding symlinks/subdirectories.

The staged build copies LICENSE, THIRD-PARTY-NOTICES.md, BRANDING.md and BRANDING.en.md into Contents/Resources, and Brand/LICENSE into Contents/Resources/Brand/LICENSE. The staged bundle verifier requires all five notice/policy files before signing. The DMG copies that complete app, so those documents accompany its app/icon/background graphics without changing the disk-image root layout.

The development repository's build scripts are unchanged. This packaging update is confined to the publication staging and was validated through shell syntax and isolated resource-copy/bundle-verifier checks; no new app or DMG was built for this documentation task.
