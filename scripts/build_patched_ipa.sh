#!/usr/bin/env bash
# Build a TrollStore-installable LANDrop 2.8.2 patched IPA.
#
# INPUT REQUIREMENT: a genuinely decrypted IPA. The original App Store IPA has
# cryptid=1 on Runner (and the Share Extension), and its FairPlay-encrypted
# 4 KiB page contains LC_MAIN. TrollStore 2.x rejects that with error 180.
# This script cannot decrypt FairPlay; use TrollDecrypt/bagbak/appdecrypt on an
# authorized device first. It replaces the Share Extension executable, so the
# input appex need not be decrypted, but Runner must be.
#
# Output is ad-hoc signed with explicit per-bundle entitlements. TrollStore
# preserves those entitlements while applying its own CoreTrust bypass. No
# developer certificate, provisioning profile, or Apple ID is needed.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT_IPA="${INPUT_IPA:-$ROOT/LANDrop-2.8.2-decrypted.ipa}"
ORIGINAL_IPA="${ORIGINAL_IPA:-}"
OUTPUT_IPA="${OUTPUT_IPA:-$ROOT/LANDrop-2.8.2-fixed-trollstore.ipa}"
BUILD="$ROOT/.build"
APP="$BUILD/Payload/Runner.app"
SHARE="$APP/PlugIns/Share Extension.appex"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
DEPLOY="14.0"
ARCH="arm64"

test -f "$INPUT_IPA"
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"
unzip -q "$INPUT_IPA"

# 1. Verify genuine decryption rather than a cryptid-only fake. When the
# original encrypted IPA is provided, also assert that the old 4 KiB FairPlay
# pages were replaced with different, lower-entropy bytes.
if [[ -n "$ORIGINAL_IPA" ]]; then
  python3 "$ROOT/tools/check_decrypted_ipa.py" "$INPUT_IPA" "$ORIGINAL_IPA" --allow-encrypted-share
else
  python3 "$ROOT/tools/check_decrypted_ipa.py" "$INPUT_IPA" --allow-encrypted-share
fi

# 2. Clean stale signatures and App Store DRM / device-thinning metadata.
# Keep MinimumOSVersion untouched: dyld uses LC_BUILD_VERSION, and changing
# Info.plist only narrows the set of installable devices.
find "$APP" -type d -name _CodeSignature -prune -exec rm -rf {} +
find "$APP" -type d -name SC_Info -prune -exec rm -rf {} +
/usr/libexec/PlistBuddy -c "Delete :ITSDRMScheme" "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :UISupportedDevices" "$APP/Info.plist" 2>/dev/null || true
# Be explicit about the suite name: compiled flutter_sharing_intent 1.1.1
# derives group.<bundle id> when AppGroupId is absent, but writing it into
# both Info.plist files removes any ambiguity for the host and the extension.
/usr/libexec/PlistBuddy -c "Set :AppGroupId group.app.landrop.landrop-flutter" "$APP/Info.plist" || \
  /usr/libexec/PlistBuddy -c "Add :AppGroupId string group.app.landrop.landrop-flutter" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :AppGroupId group.app.landrop.landrop-flutter" "$SHARE/Info.plist" || \
  /usr/libexec/PlistBuddy -c "Add :AppGroupId string group.app.landrop.landrop-flutter" "$SHARE/Info.plist"

# 3. Disable the two hard-coded CoreBluetooth power alerts. This patches two
# 4-byte immediates inside already-unencrypted plugin dylibs and deliberately
# does not modify Runner's Mach-O load commands.
python3 "$ROOT/tools/patch_bluetooth_plugins.py" "$BUILD"

# 4. Build a pure-Objective-C replacement Share Extension executable. Its
# runtime class name equals the original NIB's Swift-mangled class name, so
# MainInterface.storyboardc stays byte-identical. NSExtensionMain comes from
# Foundation; -e sets the executable's LC_MAIN to that symbol.
"$CLANG" \
  -isysroot "$SDK" -arch "$ARCH" -miphoneos-version-min="$DEPLOY" \
  -fobjc-arc -fmodules -O2 \
  -I "$ROOT/patches/ios/Share Extension" \
  -framework Foundation -framework UIKit -framework MobileCoreServices \
  -framework UniformTypeIdentifiers \
  -Wl,-e,_NSExtensionMain \
  "$ROOT/patches/ios/Share Extension/ShareViewController.m" \
  "$ROOT/patches/ios/Share Extension/main.m" \
  -o "$SHARE/Share Extension.new"
chmod +x "$SHARE/Share Extension.new"
mv "$SHARE/Share Extension.new" "$SHARE/Share Extension"
python3 "$ROOT/tools/check_share_nib.py" \
  "$SHARE/Base.lproj/MainInterface.storyboardc/UIViewController-j1y-V4-xli.nib" \
  "$SHARE/Share Extension"

# 5. Build a replacement for the flutter_sharing_intent plugin framework.
# The original plugin loses the payload whenever the Dart side reads through the
# other channel than the one the launch took (cold launch only fills
# `initialSharing`, warm launch only pushes to the event stream), which shows up
# as the app opening with nothing selected. The replacement keeps every mangled
# symbol Runner links against, so it is a drop-in for the same framework path.
SWIFTC="$(xcrun --sdk iphoneos --find swiftc)"
PLUGIN_DIR="$APP/Frameworks/flutter_sharing_intent.framework"
FLUTTER_MODULES="$APP/Frameworks/Flutter.framework/Modules"
"$SWIFTC" \
  -sdk "$SDK" -target "arm64-apple-ios$DEPLOY" \
  -module-name flutter_sharing_intent \
  -emit-library -emit-module -emit-module-path "$BUILD/flutter_sharing_intent.swiftmodule" \
  -O -whole-module-optimization \
  -Xcc -fmodule-map-file="$FLUTTER_MODULES/module.modulemap" \
  -I "$FLUTTER_MODULES" \
  -F "$APP/Frameworks" \
  -framework Flutter -framework Foundation -framework UIKit \
  -install_name "@rpath/flutter_sharing_intent.framework/flutter_sharing_intent" \
  -o "$PLUGIN_DIR/flutter_sharing_intent.new" \
  "$ROOT/patches/ios/SharingIntent/SharingIntentPlugin.swift"
chmod +x "$PLUGIN_DIR/flutter_sharing_intent.new"
mv "$PLUGIN_DIR/flutter_sharing_intent.new" "$PLUGIN_DIR/flutter_sharing_intent"
python3 "$ROOT/tools/check_plugin_symbols.py" "$PLUGIN_DIR/flutter_sharing_intent"

# 6. Generate XML entitlements plists with literal Team IDs. TrollStore reads
# entitlements from each signed Mach-O and creates App Group containers for
# both the app and the extension. It does NOT read an entitlements file in the
# bundle, and it does not expand Xcode $(AppIdentifierPrefix) variables.
python3 "$ROOT/tools/prepare_entitlements.py" \
  "$BUILD/Runner.entitlements" "$BUILD/ShareExtension.entitlements"

# 7. Ad-hoc sign nested frameworks/dylibs first, then the two bundles with
# their own entitlements, then the outer app. TrollStore will recursively
# re-sign and apply its CoreTrust bypass at install time.
find "$APP/Frameworks" -type f -perm -111 -print0 | while IFS= read -r -d '' f; do
  codesign --force --sign - --timestamp=none "$f"
done
codesign --force --sign - --timestamp=none \
  --entitlements "$BUILD/ShareExtension.entitlements" "$SHARE"
codesign --force --sign - --timestamp=none \
  --entitlements "$BUILD/Runner.entitlements" "$APP"

# 8. Structural verification: no cryptid=1, no SC_Info, both 4-byte patches,
# original NIB, URL scheme, separately signed App Group entitlements.
rm -f "$OUTPUT_IPA"
cd "$BUILD"
zip -qry "$OUTPUT_IPA" Payload
python3 "$ROOT/tools/verify_patched_ipa.py" "$OUTPUT_IPA"
shasum -a 256 "$OUTPUT_IPA"
printf 'Built for TrollStore: %s\n' "$OUTPUT_IPA"
