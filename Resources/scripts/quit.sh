#!/bin/zsh
R="$HOME/Library/Application Support/BeamNG-GPTK4"
W=$(ls -d "$R"/containers/wine_installations/*(N/) | head -1)
WINEPREFIX="$R/containers/prefixes/beamng" "$W/bin/wineserver" -k 2>/dev/null
for i in {1..20}; do pgrep -f "BeamNG.drive" >/dev/null || exit 0; sleep 0.5; done
