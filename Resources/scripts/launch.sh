#!/bin/zsh
# Starts BeamNG.drive through Wine + Apple D3DMetal (GPTK). Settings come from launcher.conf.
R="$HOME/Library/Application Support/BeamNG-GPTK4"
GAME_DIR=""; GAME_ARGS="-nogfxgpudriven"; EXTRA_ARGS=""; METAL4=1; FPS_HUD=0; GPTK_VERSION=current
[ -f "$R/launcher.conf" ] && source "$R/launcher.conf"

W=$(ls -d "$R"/containers/wine_installations/*(N/) | head -1)
GPTK="$R/gptk/$GPTK_VERSION"
LOG="$R/logs/last-launch.log"; mkdir -p "$R/logs"
fail() { osascript -e "display alert \"BeamNG launcher\" message \"$1\""; echo "$1" >> "$LOG"; exit 1; }
[ -x "$W/bin/wine" ] || fail "Wine runtime is missing. Open the launcher and run setup."
[ -f "$GPTK/external/libd3dshared.dylib" ] || fail "GPTK is not installed. Open the launcher and install the Apple .dmg."
[ -f "$GAME_DIR/BeamNG.drive.exe" ] || fail "BeamNG.drive.exe not found in: $GAME_DIR"

export WINEPREFIX="$R/containers/prefixes/beamng"
export WINEARCH=win64 WINEMSYNC=1 WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLPATH="$GPTK/wine"
export WINE_GPTK_LIBD3DSHARED_PATH="$GPTK/external/libd3dshared.dylib"
export DYLD_FALLBACK_LIBRARY_PATH="$W/lib:$W/lib/wine/x86_64-unix"
export PATH="$W/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
[ "$METAL4" = 1 ] && export D3DM_MTL4=1
[ "$FPS_HUD" = 1 ] && export MTL_HUD_ENABLED=1

echo "== $(date) gptk=$(readlink "$GPTK" || echo "$GPTK_VERSION") metal4=$METAL4 fps=$FPS_HUD args=$GAME_ARGS $EXTRA_ARGS" > "$LOG"
cd "$GAME_DIR"
"$W/bin/wine" "$GAME_DIR/BeamNG.drive.exe" ${=GAME_ARGS} ${=EXTRA_ARGS} >> "$LOG" 2>&1
"$W/bin/wineserver" -w
