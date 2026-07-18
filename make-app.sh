#!/bin/bash
# Assembles DriveAtlas.app from the SPM build product.
#
# An .app is just a directory with an Info.plist and a binary, so we don't need an
# Xcode project. Run this, then open DriveAtlas.app (or drag it to /Applications).
#
#   ./make-app.sh            # debug build
#   ./make-app.sh release    # optimised — noticeably faster on large drives

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="DriveAtlas.app"
BUNDLE_ID="com.driveatlas.app"

echo "Building (${CONFIG})..."
swift build -c "$CONFIG" --product DriveMapperApp

BIN=".build/$CONFIG/DriveMapperApp"
[ -f "$BIN" ] || { echo "Build product missing at $BIN"; exit 1; }

# Regenerate the icon when the source art is newer than the .icns (or the .icns
# is missing). Source PNGs arrive on an opaque white background; Tools/makeicon
# knocks that out and packs the sizes macOS wants.
ICON_SRC="$(ls -t ./*.png 2>/dev/null | head -1 || true)"
if [ -n "$ICON_SRC" ]; then
    if [ ! -f AppIcon.icns ] || [ "$ICON_SRC" -nt AppIcon.icns ]; then
        echo "Generating icon from $(basename "$ICON_SRC")..."
        swift Tools/makeicon.swift "$ICON_SRC" AppIcon.icns || \
            echo "  (icon generation failed — continuing without it)"
    fi
fi

echo "Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DriveAtlas"

# GRDB ships a resource bundle; without it SQLite features fail at runtime.
for bundle in .build/"$CONFIG"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    ICON_PLIST_ENTRY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
    ICON_PLIST_ENTRY=""
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DriveAtlas</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>DriveAtlas</string>
    <key>CFBundleDisplayName</key><string>DriveAtlas</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    $ICON_PLIST_ENTRY

    <!-- Regular app: shows in the Dock and has a window, plus a menu bar item.
         Set this to <true/> to make it a pure background agent with only the
         menu bar icon and no Dock presence. -->
    <key>LSUIElement</key><false/>

    <!-- Shown in the macOS prompt when the app first reads a removable volume.
         Without this key the prompt is silently denied. -->
    <key>NSRemovableVolumesUsageDescription</key>
    <string>DriveAtlas catalogs the folders on your external drives so you can find them later.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>DriveAtlas needs access to scan folders you point it at.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>DriveAtlas needs access to scan folders you point it at.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough to run locally; TCC permission grants are keyed to the
# signature, so re-signing on each build means macOS may re-prompt.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "  (ad-hoc signing failed — the app will still run)"

echo
echo "Built $APP"
echo "  open $APP          # launch it"
echo "  open -a \"$PWD/$APP\""
echo
echo "First run: macOS will ask for access to removable volumes. Grant it, or"
echo "give the app Full Disk Access in System Settings > Privacy & Security."
