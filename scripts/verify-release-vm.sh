#!/bin/bash
# Run from the transferred checkout on an Apple silicon macOS VM.
set -u
set -o pipefail
umask 077
export GIT_OPTIONAL_LOCKS=0 LC_ALL=C

while IFS= read -r name; do
    case "$name" in AMBIENT_*|WUPSY_*) unset "$name" ;; esac
done < <(compgen -e)
unset BUILD_NUMBER SIGNING_IDENTITY

EXPECTED_HEAD="${1:-cce284863797acf05d9f31092734239d688341fa}"
EXPECTED_VERSION="${2:-0.8.0}"
EXPECTED_BUILD="${3:-4}"
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wupsy-release-vm.XXXXXXXX")" || exit 1
export DIST_DIR="$LOG_DIR/dist" SWIFTPM_BUILD_DIR="$LOG_DIR/swiftpm"
APP="$DIST_DIR/Wupsy.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
steps=()
codes=()
failed=0
build_started=0
tests_started=0

run() {
    local step="$1" rc
    shift
    printf '\n== %s ==\n' "$step"
    "$@" 2>&1 | tee "$LOG_DIR/$step.log"
    rc=$?
    steps+=("$step")
    codes+=("$rc")
    if [ "$rc" -ne 0 ]; then
        failed=1
        printf 'FEHLER [%s] Exit-Code %s\n' "$step" "$rc"
    fi
    return "$rc"
}

skip() {
    local step="$1" reason="$2"
    printf 'Übersprungen. %s\n' "$reason" | tee "$LOG_DIR/$step.log"
    steps+=("$step")
    codes+=("übersprungen")
}

equal() {
    if [ "$2" != "$3" ]; then
        printf '%s: erwartet %s, gefunden %s\n' "$1" "$3" "$2" >&2
        return 1
    fi
    printf '%s %s\n' "$1" "$2"
}

preflight() (
    sw_vers && xcodebuild -version && swift --version || exit 1
    equal Architektur "$(uname -m)" arm64 || exit 1
    equal HEAD "$(git rev-parse HEAD)" "$EXPECTED_HEAD" || exit 1
    for path in VERSION scripts/config.sh scripts/build-app.sh scripts/verify-app.py "$LSREGISTER"; do
        if [ ! -r "$path" ]; then
            printf 'Datei fehlt oder ist nicht lesbar: %s\n' "$path" >&2
            exit 1
        fi
    done
    source scripts/config.sh || exit 1
    equal Version "$VERSION" "$EXPECTED_VERSION" || exit 1
    equal Build "$BUILD_NUMBER" "$EXPECTED_BUILD" || exit 1
    equal App-Pfad "$APP_PATH" "$APP" || exit 1
    printf 'Lokale Release-Änderungen sind zulässig. Tests laufen ohne strikte Metal-Präsentation.\n'
)

diff_check() {
    local rc=0
    git diff --check || rc=1
    git diff --cached --check || rc=1
    git diff HEAD --check || rc=1
    return "$rc"
}

verify_app() (
    local binary="$APP/Contents/MacOS/Wupsy" resources="$APP/Contents/Resources"
    local arch signature notice
    python3 scripts/verify-app.py "$APP" "$EXPECTED_VERSION" "$EXPECTED_BUILD" || exit 1
    plutil -lint "$APP/Contents/Info.plist" || exit 1
    arch="$(xcrun lipo -archs "$binary")" || exit 1
    equal Architektur "$arch" arm64 || exit 1
    xcrun vtool -show-build "$binary" || exit 1
    codesign --verify --deep --strict --verbose=2 "$APP" || exit 1
    signature="$(codesign -dv --verbose=2 "$APP" 2>&1)" || exit 1
    printf '%s\n' "$signature"
    printf '%s\n' "$signature" | grep -Fx 'Signature=adhoc' >/dev/null || exit 1
    for notice in LICENSE THIRD-PARTY-NOTICES.md BRANDING.md BRANDING.en.md Brand/LICENSE; do
        cmp "$ROOT/$notice" "$resources/$notice" || exit 1
    done
    printf 'Bundle, Signatur und Hinweise geprüft. Deutsch und Englisch wurden im Build geprüft.\n'
)

geometry_warnings() {
    awk '
        /^[[:space:]]*Test (Case|Suite)[[:space:]]/ { next }
        {
            line = tolower($0)
            invalid_number = "(^|[^[:alnum:]_])(nan|infinity|non[-[:space:]]finite)([^[:alnum:]_]|$)"
            if (line ~ /invalid frame dimension|negative or non[-[:space:]]finite|invalid geometry/ ||
                (line ~ /geometry|(^|[^[:alnum:]_])(frame|position|size)([^[:alnum:]_]|$)/ &&
                 line ~ invalid_number) ||
                line ~ /onchange.*multiple times per frame/) {
                if (!seen[$0]++) print
            }
        }
    ' "$@"
}

report() {
    local rc=0 build_log="$LOG_DIR/04-release-build.log" test_log="$LOG_DIR/07-tests.log"
    if [ "$build_started" -eq 1 ]; then
        awk '
            match($0, /(^|[[:space:]])(warning|Warning):[[:space:]]*/) {
                message = substr($0, RSTART + RLENGTH)
                sub(/[[:space:]]+$/, "", message)
                if (length(message)) print message
            }
        ' "$build_log" | sort -u > "$LOG_DIR/build-warnings.txt" || return 1
        awk 'END { printf "Unterschiedliche Buildwarnungen nach Meldungstext: %d\n", NR }' "$LOG_DIR/build-warnings.txt"
        cat "$LOG_DIR/build-warnings.txt"
    else
        printf 'Buildwarnungen nicht ausgewertet. Der Build wurde nicht gestartet.\n'
    fi
    if [ "$tests_started" -eq 0 ]; then
        printf 'XCTest und SwiftUI-Geometriewarnungen nicht ausgewertet. Die Tests wurden nicht gestartet.\n'
        return 0
    fi

    printf '\nXCTest-Gesamtergebnis\n'
    awk '
        /^Test Suite '\''All tests'\'' (passed|failed) at / {
            suite = $0
            summary = ""
            if (getline > 0 && $0 ~ /Executed [0-9]+ tests?/) summary = $0
        }
        END {
            if (suite == "" || summary == "") {
                print "Kein vollständiger XCTest-Abschluss im Protokoll."
                exit 1
            }
            print suite
            print summary
            if (suite ~ / failed at /) exit 1
        }
    ' "$test_log" || rc=1
    awk '
        /^Test Case / && / (passed|failed|skipped) \(/ {
            name = $0
            sub(/ (passed|failed|skipped) \(.*/, "", name)
            if ($0 ~ / failed \(/) status[name] = "failed"
            else if ($0 ~ / skipped \(/ && status[name] != "failed") status[name] = "skipped"
            else if (!(name in status)) status[name] = "passed"
        }
        END {
            for (name in status) count[status[name]]++
            printf "Bestanden %d | Fehlgeschlagen %d | Übersprungen %d (Testfälle, eindeutig)\n",
                   count["passed"], count["failed"], count["skipped"]
        }
    ' "$test_log" || rc=1

    printf '\nFehlgeschlagene und übersprungene Tests mit Diagnosen\n'
    awk '
        /^Test Case / && / (failed|skipped) \(/ ||
        /Test skipped -|: error: -\[/ ||
        /(^|[[:space:]])(Fatal error|error):/ {
            if (!seen[$0]++) { print; found = 1 }
        }
        END { if (!found) print "Keine entsprechenden Meldungen im Testprotokoll." }
    ' "$test_log" || rc=1

    printf '\nSwiftUI-Geometriewarnungen im Build- und Testprotokoll\n'
    if geometry_warnings "$build_log" "$test_log" > "$LOG_DIR/geometry-warnings.txt"; then
        if [ -s "$LOG_DIR/geometry-warnings.txt" ]; then
            cat "$LOG_DIR/geometry-warnings.txt"
            rc=1
        else
            printf 'Keine Treffer.\n'
        fi
    else
        printf 'Geometriewarnungssuche konnte nicht abgeschlossen werden.\n'
        rc=1
    fi
    return "$rc"
}

printf 'Protokolle %s\n' "$LOG_DIR"
if run 01-ausgangslage preflight; then
    run 02-formatierung /bin/bash scripts/format.sh --check
    run 03-git-diff diff_check
    build_started=1
    if run 04-release-build /bin/bash scripts/build-app.sh; then
        if run 05-app-bundle-signatur verify_app; then
            if run 06-app-registrierung "$LSREGISTER" -f "$APP"; then
                tests_started=1
                run 07-tests swift test --build-system swiftbuild --jobs 2
            else
                skip 07-tests 'Die App-Registrierung ist fehlgeschlagen.'
            fi
        else
            skip 06-app-registrierung 'Die Bundle- oder Signaturprüfung ist fehlgeschlagen.'
            skip 07-tests 'Es liegt keine geprüfte und registrierte Release-App vor.'
        fi
    else
        skip 05-app-bundle-signatur 'Der Release-Build ist fehlgeschlagen.'
        skip 06-app-registrierung 'Es liegt kein erfolgreicher Release-Build vor.'
        skip 07-tests 'Es liegt kein erfolgreicher Release-Build vor.'
    fi
else
    for step in 02-formatierung 03-git-diff 04-release-build 05-app-bundle-signatur 06-app-registrierung 07-tests; do
        skip "$step" 'Die Prüfung der Ausgangslage ist fehlgeschlagen.'
    done
fi

run 08-auswertung report
run 09-git-status git status --short --branch --untracked-files=normal

{
    printf '\n%-30s %s\n' 'Prüfschritt' 'Exit-Code'
    for ((i=0; i<${#steps[@]}; i++)); do
        printf '%-30s %s\n' "${steps[$i]}" "${codes[$i]}"
    done
    printf '%-30s %s\n' 'Gesamtergebnis' "$failed"
    printf '\nProtokolle %s\n' "$LOG_DIR"
    if [ -d "$APP" ]; then printf 'Release-App %s\n' "$APP"; fi
} | tee "$LOG_DIR/00-zusammenfassung.log" || failed=1

exit "$failed"
