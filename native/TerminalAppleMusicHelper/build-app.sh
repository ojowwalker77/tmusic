#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER_DIR="$ROOT_DIR/native/TerminalAppleMusicHelper"
OUTPUT_DIR="$ROOT_DIR/.build-helper"
APP_DIR="$OUTPUT_DIR/TerminalAppleMusicHelper.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/TerminalAppleMusicHelper"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
SIGNING_IDENTITY="${TERMINAL_APPLE_MUSIC_SIGNING_IDENTITY:--}"
USE_ENTITLEMENTS="${TERMINAL_APPLE_MUSIC_USE_ENTITLEMENTS:-0}"

mkdir -p /tmp/clang-module-cache /tmp/swift-module-cache

CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
SWIFT_MODULECACHE_PATH=/tmp/swift-module-cache \
swift build --disable-sandbox -c release --package-path "$HELPER_DIR"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$HELPER_DIR/.build/release/TerminalAppleMusicHelper" "$EXECUTABLE"
cp "$HELPER_DIR/Info.plist" "$INFO_PLIST"

if [[ "$USE_ENTITLEMENTS" == "1" ]]; then
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$HELPER_DIR/TerminalAppleMusicHelper.entitlements" \
    "$APP_DIR"
else
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"
fi
