#!/bin/zsh
# Starts BeamNG.drive through Wine + Apple D3DMetal (GPTK). Settings come from launcher.conf.
# Optional helpers started first, in the same Wine prefix: BeamMP (multiplayer) and BeamNG.Earth (world server).
R="$HOME/Library/Application Support/BeamNG-GPTK4"
GAME_DIR=""; GAME_ARGS="-nogfxgpudriven"; EXTRA_ARGS=""; METAL4=1; FPS_HUD=0; GPTK_VERSION=current
BEAMMP=0; EARTH=0; RENDERER=d3d12
[ -f "$R/launcher.conf" ] && source "$R/launcher.conf"

W=$(ls -d "$R"/containers/wine_installations/*(N/) | head -1)
GPTK="$R/gptk/$GPTK_VERSION"
ADDONS="$R/addons"
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

# Renderer. d3d12/d3d11 go through Apple D3DMetal. vulkan is BeamNG's own Vulkan renderer on
# MoltenVK (Vulkan on Metal, ships with Wine). dxvk is the game's D3D11 renderer translated to
# Vulkan by DXVK-macOS, then to Metal by MoltenVK.
GFX=""
case "$RENDERER" in
  d3d11) GFX="-gfx dx11" ;;
  vulkan) GFX="-gfx vulkan" ;;
  dxvk)
    [ -f "$ADDONS/dxvk/x86_64-windows/d3d11.dll" ] || fail "DXVK is picked as the renderer but not installed. Install it in the launcher."
    GFX="-gfx dx11"
    export WINEDLLPATH="$ADDONS/dxvk"          # DXVK's d3d11 instead of D3DMetal's
    export DXVK_ASYNC=1 DXVK_LOG_LEVEL=warn DXVK_LOG_PATH="$R/logs"
    [ "$FPS_HUD" = 1 ] && export DXVK_HUD=fps
    ;;
esac
if [ "$RENDERER" = vulkan ] || [ "$RENDERER" = dxvk ]; then
  export MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1 MVK_CONFIG_RESUME_LOST_DEVICE=1
  export MVK_CONFIG_LOG_LEVEL=1
fi

echo "== $(date) gptk=$(readlink "$GPTK" || echo "$GPTK_VERSION") metal4=$METAL4 fps=$FPS_HUD beammp=$BEAMMP earth=$EARTH renderer=$RENDERER args=$GFX $GAME_ARGS $EXTRA_ARGS" > "$LOG"

wait_port() {   # port, seconds. lsof, not a test connection: BeamMP would take one for the game
  for i in {1..$2}; do lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
stop_helpers() {
  pkill -f "BeamMP-Launcher.exe" 2>/dev/null
  pkill -f "BeamNG.Earth.exe" 2>/dev/null
}
trap stop_helpers EXIT

if [ "$EARTH" = 1 ]; then
  E="$ADDONS/beamng-earth/BeamNG.Earth.exe"
  [ -f "$E" ] || fail "BeamNG.Earth is turned on but not installed. Install it in the launcher."
  echo "starting BeamNG.Earth world server" >> "$LOG"
  ( cd "$ADDONS/beamng-earth" && "$W/bin/wine" "$E" --no-game --no-beammp --no-update-check \
      --user-dir 'C:\users\steamuser\AppData\Local\BeamNG\BeamNG.drive\current' > "$R/logs/beamng-earth.log" 2>&1 ) &
  if wait_port 47613 300; then echo "BeamNG.Earth server is listening" >> "$LOG"
  else echo "BeamNG.Earth server did not start listening in 5 minutes; starting the game anyway" >> "$LOG"; fi
fi

if [ "$BEAMMP" = 1 ]; then
  B="$ADDONS/beammp/BeamMP-Launcher.exe"
  [ -f "$B" ] || fail "Multiplayer is turned on but BeamMP is not installed. Install it in the launcher."
  echo "starting BeamMP launcher" >> "$LOG"
  ( cd "$ADDONS/beammp" && "$W/bin/wine" "$B" --no-launch > "$R/logs/beammp.log" 2>&1 ) &
  if wait_port 4444 180; then echo "BeamMP launcher is listening" >> "$LOG"
  else echo "BeamMP launcher did not start listening in 3 minutes; starting the game anyway" >> "$LOG"; fi
fi

cd "$GAME_DIR"
"$W/bin/wine" "$GAME_DIR/BeamNG.drive.exe" ${=GFX} ${=GAME_ARGS} ${=EXTRA_ARGS} >> "$LOG" 2>&1
if [ "$BEAMMP" = 1 ] || [ "$EARTH" = 1 ]; then
  # BeamNG.drive.exe hands over to BeamNG.drive.x64.exe: wait for the game itself, then stop the helpers
  for i in {1..60}; do pgrep -f "BeamNG.drive.x64.exe" >/dev/null && break; sleep 1; done
  while pgrep -f "BeamNG.drive.x64.exe" >/dev/null; do sleep 2; done
  stop_helpers
fi
"$W/bin/wineserver" -w
