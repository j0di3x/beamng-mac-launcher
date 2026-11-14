#!/bin/zsh
# Imports Wine and a Windows container from GameHub (com.gamemac.www) into the launcher's own folder.
set -e
R="$HOME/Library/Application Support/BeamNG-GPTK4"
GH="$HOME/Library/Application Support/com.gamemac.www/wine-engine/containers"
[ -d "$GH" ] || { echo "GameHub not found. Install GameHub and run any Windows game once, then try again."; exit 1; }
pgrep -f "BeamNG.drive" >/dev/null && { echo "Quit BeamNG first."; exit 1; }
WSRC=$(ls -d "$GH"/wine_installations/*(N/) | while read d; do [ -x "$d/bin/wine" ] && echo "$d"; done | head -1)
BSRC=$(ls -d "$GH"/base_containers/*(N/) | head -1)
[ -n "$WSRC" ] && [ -n "$BSRC" ] || { echo "GameHub has no Wine or base container yet. Run a game in GameHub once."; exit 1; }
# prefer the GameHub container that already has BeamNG, else the newest one
VSRC=""; for d in $(ls -dt "$GH"/virtual_containers/*(N/)); do [ -d "$d/drive_c/users/steamuser/AppData/Local/BeamNG" ] && { VSRC="$d"; break; }; done
[ -z "$VSRC" ] && VSRC=$(ls -dt "$GH"/virtual_containers/*(N/) | head -1)
ID=$(basename "$WSRC")
mkdir -p "$R/containers/wine_installations" "$R/containers/prefixes"
rm -rf "$R/containers/wine_installations/$ID" "$R/containers/prefixes/beamng"
cp -cR "$WSRC" "$R/containers/wine_installations/$ID"
cp -cR "$BSRC" "$R/containers/prefixes/beamng"
if [ -n "$VSRC" ]; then
  cd "$VSRC"
  find . -mindepth 1 \( -path ./.gamehub -o -path "./.we_prefix*" \) -prune -o -print | while IFS= read -r p; do
    if [ -d "$p" ] && [ ! -L "$p" ]; then mkdir -p "$R/containers/prefixes/beamng/$p"
    else rm -rf "$R/containers/prefixes/beamng/$p"; cp -cPp "$p" "$R/containers/prefixes/beamng/$p"; fi
  done
fi
cd "$R/containers/prefixes/beamng/dosdevices"; for l in *(N@); do [ "$l" = "z:" ] || rm -f "$l"; done; ln -sfn ../drive_c c:
# remove any older wine copies so only one runtime is present
for d in "$R"/containers/wine_installations/*(N/); do [ "$(basename "$d")" = "$ID" ] || rm -rf "$d"; done
echo "Imported Wine $ID from GameHub${VSRC:+ (with $(basename "$VSRC")'s settings)}"
