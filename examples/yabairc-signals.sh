#!/usr/bin/env bash
# Add to ~/.yabairc (adjust BIN to the built binary path printed by scripts/bundle.sh).
BIN="$HOME/Project/stackline/yabai-dockstack.app/Contents/MacOS/yabai-dockstack"
for evt in window_focused window_moved window_resized window_created \
           window_destroyed space_changed display_changed application_front_switched \
           window_minimized window_deminimized application_hidden application_visible \
           application_terminated; do
  extra=""
  [ "$evt" = display_changed ] && extra=" --force"
  yabai -m signal --add event="$evt" action="$BIN --refresh$extra"
done
