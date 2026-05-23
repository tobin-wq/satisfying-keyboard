#!/bin/bash
# Build capybara.app — a system-wide mechanical-keyboard sound app for macOS.
#
# Each version produces a distinct app bundle (e.g., "capybara 1.3.app" with
# bundle ID local.capybara.v1-3) so macOS treats it as a fresh app — no
# inherited TCC permissions from previous builds. Lets you test new builds
# without wrestling with stale Accessibility/Input Monitoring entries.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
VERSION_BUNDLE=$(echo "$VERSION" | tr '.' '-')          # 1.3 -> 1-3 (bundle IDs prefer no dots)
APP="capybara ${VERSION}.app"
EXE="capybara"
BUNDLE_ID="local.capybara.v${VERSION_BUNDLE}"
BUNDLE_NAME="capybara ${VERSION}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Compile the Swift sources.
swiftc -O \
    -o "$APP/Contents/MacOS/$EXE" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework ApplicationServices \
    capybara-src/main.swift

# Copy Info.plist and patch in the version-specific name + identifier so this
# build is a fully separate app to macOS.
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName '${BUNDLE_NAME}'"        "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName '${BUNDLE_NAME}'" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier '${BUNDLE_ID}'"    "$APP/Contents/Info.plist"

# Bundle every switch sprite + the menu-bar logo.
cp *_sprite.wav "$APP/Contents/Resources/"
[ -f capylogo.png ] && cp capylogo.png "$APP/Contents/Resources/"

# Ad-hoc sign so macOS Gatekeeper will let it run locally.
codesign --force --sign - --deep "$APP" 2>/dev/null || true

echo
echo "Built '$APP' (bundle id: $BUNDLE_ID)"
echo "Launch with:  open '$APP'"
echo
echo "First launch will prompt for Accessibility AND Input Monitoring access."
