#!/bin/bash
# Builds Ara, installs it to /Applications and starts it.
#
# Works on any Mac with Apple silicon, macOS 26 or newer and Xcode 26 or newer.
# The app is signed with the first "Apple Development" certificate in the
# keychain. A free Apple ID added in Xcode (Settings → Accounts) provides one.
# Without it the app is signed ad hoc: it runs, but macOS asks again for the
# Accessibility permission after every new install.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "✗ $1" >&2; exit 1; }
info() { echo "→ $1"; }

# --- Requirements -------------------------------------------------------------

[[ "$(uname -m)" == "arm64" ]] || fail "Ara needs a Mac with Apple silicon (M1 or newer)."

macos_major=$(sw_vers -productVersion | cut -d. -f1)
(( macos_major >= 26 )) || fail "Ara needs macOS 26 or newer (this Mac runs $(sw_vers -productVersion))."

if ! xcode_version=$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $2}') || [[ -z "$xcode_version" ]]; then
    fail "Xcode is missing. Install it from the App Store, open it once, then run this script again.
  If Xcode is installed, point the command line tools to it:
  sudo xcode-select -s /Applications/Xcode.app"
fi
(( ${xcode_version%%.*} >= 26 )) || fail "Ara needs Xcode 26 or newer (found $xcode_version)."

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    fail "Xcode still has to finish its first launch. Open Xcode once, or run:
  sudo xcodebuild -runFirstLaunch"
fi

# --- Signing ------------------------------------------------------------------

identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if [[ -n "$identity" ]]; then
    # The team ID is the OU field of the certificate's subject.
    team=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject -nameopt multiline \
        | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')
    [[ -n "$team" ]] || fail "Could not read the team from the certificate \"$identity\"."
    info "Signing with $identity (team $team)"
    signing=(DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development")
else
    echo "! No Apple Development certificate found, so Ara is signed ad hoc."
    echo "  It works, but every new install asks again for the Accessibility permission."
    echo "  To avoid that: Xcode → Settings → Accounts → add your Apple ID (free), then run this script again."
    signing=(DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-")
fi

# --- Build and install --------------------------------------------------------

info "Building Ara (the first build downloads the dependencies and takes a few minutes)…"
log=$(mktemp -t ara-build)
if ! xcodebuild -project Ara.xcodeproj -scheme Ara -configuration Release -derivedDataPath build \
    "${signing[@]}" -quiet build >"$log" 2>&1; then
    grep -E "error:" "$log" | sort -u | head -20 >&2 || true
    fail "The build failed. Full log: $log"
fi
rm -f "$log"

info "Installing to /Applications…"
pkill -x Ara 2>/dev/null || true
# Opening the new copy while the old one is still quitting fails with error -600.
for _ in {1..50}; do pgrep -x Ara >/dev/null || break; sleep 0.1; done
rm -rf /Applications/Ara.app
ditto build/Build/Products/Release/Ara.app /Applications/Ara.app
open /Applications/Ara.app

cat <<'EOF'
✓ Ara is installed and running (the icon is in the menu bar).

On first launch:
  1. Allow Ara in System Settings → Privacy & Security → Accessibility, so it can paste.
  2. Allow the microphone when asked (on the first recording).
  3. Wait until the menu shows "Ready". The speech model (about 600 MB) downloads once.

Dictate with ⌥ Space: press once to start, once more to stop.
EOF
