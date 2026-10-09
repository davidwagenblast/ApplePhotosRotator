#!/usr/bin/env bash
# One-step build and install of Photo Rotator.
#
# On a Mac without a copy of the code, paste this into Terminal:
#   curl -fsSL https://raw.githubusercontent.com/davidwagenblast/ApplePhotosRotator/main/install.sh | bash
#
# From a copy of this repository:
#   ./install.sh                  (or double-click "Install Photo Rotator.command" in Finder)
#
# It checks the Mac is ready, downloads or updates the code if needed, builds the app, installs it in
# /Applications (~/Applications if /Applications isn't writable) and opens it. Run it again to update.
#
# Options: --no-open (install without opening). INSTALL_DIR=/path installs somewhere else.
set -euo pipefail

REPO_URL="${PHOTO_ROTATOR_REPO:-https://github.com/davidwagenblast/ApplePhotosRotator.git}"
APP_NAME="Photo Rotator.app"
OPEN_APP=1
for arg in "$@"; do
    case "$arg" in
        --no-open) OPEN_APP=0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '\nError: %s\n' "$1" >&2; exit 1; }

# 1. Is this Mac ready?
[ "$(uname -s)" = Darwin ] || fail "Photo Rotator is a Mac app. Run this on a Mac."
macos_version="$(sw_vers -productVersion)"
[ "${macos_version%%.*}" -ge 14 ] || fail "Photo Rotator needs macOS 14 Sonoma or later. This Mac has macOS $macos_version."

# Swift and git come with Apple's free Command Line Tools (or Xcode).
if ! xcrun --find swift >/dev/null 2>&1 || ! xcrun --find git >/dev/null 2>&1; then
    step "Installing Apple's Command Line Tools (needed once to build the app)"
    xcode-select --install >/dev/null 2>&1 || true
    fail "Finish the Command Line Tools installation in the window that just opened, then run this again."
fi
swift_version="$(xcrun swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)"
swift_major="${swift_version%%.*}"
swift_minor="${swift_version#*.}"
if [ -z "$swift_version" ] || [ "$swift_major" -lt 5 ] || { [ "$swift_major" -eq 5 ] && [ "$swift_minor" -lt 9 ]; }; then
    fail "Building needs Swift 5.9 or later (found ${swift_version:-none}). Update Xcode or the Command Line Tools in System Settings › General › Software Update."
fi

# 2. The code: this folder when run from a copy of the repository, otherwise a downloaded copy.
script_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$script_dir" ] && [ -f "$script_dir/Package.swift" ]; then
    source_dir="$script_dir"
else
    source_dir="${PHOTO_ROTATOR_SOURCE:-$HOME/Library/Caches/PhotoRotator/source}"
    if [ -d "$source_dir/.git" ]; then
        step "Updating the code"
        git -C "$source_dir" pull --ff-only --quiet
    else
        step "Downloading the code"
        rm -rf "$source_dir"
        mkdir -p "$(dirname "$source_dir")"
        git clone --depth 1 --quiet "$REPO_URL" "$source_dir"
    fi
fi

# 3. Build.
step "Building Photo Rotator (the first build takes a few minutes)"
"$source_dir/scripts/build_app.sh"

# 4. Install, replacing any earlier copy.
destination="${INSTALL_DIR:-/Applications}"
if [ -z "${INSTALL_DIR:-}" ] && [ ! -w /Applications ]; then
    destination="$HOME/Applications"
fi
mkdir -p "$destination"
if pgrep -x PhotoRotator >/dev/null 2>&1; then
    step "Quitting the running copy"
    osascript -e 'tell application "Photo Rotator" to quit' >/dev/null 2>&1 || true
    sleep 2
fi
rm -rf "${destination:?}/$APP_NAME"
ditto "$source_dir/build/$APP_NAME" "$destination/$APP_NAME"
step "Installed $destination/$APP_NAME"

# 5. Open.
if [ "$OPEN_APP" = 1 ]; then
    open "$destination/$APP_NAME"
    echo "Photo Rotator is opening. On first launch, choose Allow Full Access when macOS asks about Photos."
fi
