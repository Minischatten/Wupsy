# Security reports

For vulnerabilities, use the repository's private GitHub vulnerability-reporting form when available. Do not post exploit details, credentials or private files in a public issue. If private reporting is unavailable, open an issue requesting a private contact without including sensitive details.

Wupsy is an early preview without a guaranteed response time. The current release is the only supported line.

Web wallpapers run imported JavaScript and may access the network. Use trusted content. Importing a single HTML file copies only that file; importing a folder copies everything in it, so select only a folder that belongs to the wallpaper. Local read access of a web wallpaper is limited to its managed folder. Web wallpapers imported by a published release up to 0.8.0 from a single file may contain the whole former parent folder; remove and import them again to drop those copies. Custom HTML/CSS widgets are a separate offline renderer: page scripts, remote resources, frames and native command access are disabled. The app is not a security boundary for arbitrary hostile wallpaper files.

Builds are currently ad-hoc signed and not notarized. Verify release origins and checksums. Never disable Gatekeeper globally to run Wupsy.
