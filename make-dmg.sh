#!/bin/zsh
# Builds the app and packs it into dist/BeamNG-Launcher-<version>.dmg (drag-to-Applications layout).
set -e
cd "${0:A:h}"
./build.sh
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
STAGE=$(mktemp -d)/BeamNG\ Launcher
mkdir -p "$STAGE"
ditto "build/BeamNG Launcher.app" "$STAGE/BeamNG Launcher.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<TXT
BeamNG Launcher for Mac $VER (unofficial)

1. Drag "BeamNG Launcher" onto the Applications folder.
2. The first time, RIGHT-CLICK the app and choose Open (it is not notarized by Apple).
   If macOS still refuses: System Settings > Privacy & Security > "Open Anyway".
3. In the launcher, finish the setup checklist:
   - Import from GameHub (needs GameHub installed and any Windows game run once)
   - Install .dmg... (Apple's "Evaluation environment for Windows games 4.0",
     free download at developer.apple.com/download)
   - Choose your BeamNG.drive folder
4. Press Play.

Source and help: https://github.com/j0di3x/beamng-mac-launcher
TXT
mkdir -p dist
OUT="dist/BeamNG-Launcher-$VER.dmg"
rm -f "$OUT"
hdiutil create -volname "BeamNG Launcher" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
rm -rf "${STAGE:h}"
shasum -a 256 "$OUT"
