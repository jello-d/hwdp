#!/bin/sh
# hotplug.t - `hwdp watch` reacts to the DISPLAY SET changing, not just to the
# compositor config file.
#
# The gap this closes was found on real hardware: `watch` inotified wayfire.ini
# and nothing else, generated kanshi's config once at startup and never again.
# A monitor was plugged in and the runtime config still described the panel it
# replaced -- four days stale, with `watch` up the whole time. kanshi therefore
# had no profile matching the new arrangement, the new panel kept whatever the
# compositor gave it, and the `changed` hooks never fired.
#
# Driven entirely through a fake DRM tree: connectors are directories, so
# "plugging in a monitor" is `mkdir` and unplugging is `rm -rf`. No compositor,
# no hardware.
. "$(dirname "$0")/lib.sh"
harness_init hotplug

MGR=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/hooks/changed.d" "$T/run" "$T/home" "$T/drm"

# The watchdog TERMs the supervisor when the compositor socket disappears, so
# it needs a REAL socket to stat.
python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
  "$T/run/wayland-test" 2>/dev/null || skip "cannot make a unix socket"

for _c in kanshi inotifywait; do
  printf '#!/bin/sh\nexec sleep 3600\n' > "$T/bin/$_c"
  chmod +x "$T/bin/$_c"
done

# A wlr-randr stub that DERIVES from the same fake DRM tree, so the layout side
# and the panels side cannot disagree about what is plugged in. Without this
# the layout provider answers nothing, cmd/layout writes no config, and the
# "was it regenerated?" assertion degrades to none-vs-something -- true by
# accident rather than because a regeneration happened.
cat > "$T/bin/wlr-randr" <<EOF
#!/bin/sh
_x=0
for _d in "$T"/drm/card0-*/; do
  [ -d "\$_d" ] || continue
  _n=\$(basename "\$_d"); _n=\${_n#card0-}
  _m=\$(head -1 "\$_d/modes" 2>/dev/null)
  _w=\${_m%%x*}; _h=\${_m##*x}
  _s=\$(cksum < "\$_d/edid" | cut -d' ' -f1)
  echo "\$_n \"Acme Inc. PANEL \$_s (\$_n)\""
  echo "  Make: Acme Inc."
  echo "  Model: PANEL"
  echo "  Serial: \$_s"
  echo "  Physical size: 530x300 mm"
  echo "  Enabled: yes"
  echo "  Modes:"
  echo "    \${_w}x\${_h} px, 60.000000 Hz (current)"
  echo "  Position: \${_x},0"
  echo "  Transform: normal"
  echo "  Scale: 1.000000"
  _x=\$((_x + _w))
done
EOF
chmod +x "$T/bin/wlr-randr"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pkill"; chmod +x "$T/bin/pkill"

cat > "$T/hooks/changed.d/10-record" <<EOF
#!/bin/sh
echo changed >> "$T/changed.log"
EOF
chmod +x "$T/hooks/changed.d/10-record"

# panel <name> <edid-seed> <mode>: a connector as the DRM provider reads one.
# The edid must hash to something that is neither empty nor the empty-string
# sha, or the provider skips it (see its own GOTCHA note).
panel() {
  mkdir -p "$T/drm/card0-$1"
  printf 'connected\n' > "$T/drm/card0-$1/status"
  printf '%s' "$2" > "$T/drm/card0-$1/edid"
  printf '%s\n' "$3" > "$T/drm/card0-$1/modes"
}
panel DP-1 edid-one 1920x1080

: > "$T/wayfire.ini"

# HOME and the profile paths are pinned into $T for the reason mgr.t records:
# `watch` runs cmd/layout IN PROCESS, so without them a run writes a real
# sticky scale into the developer's own ~/.config.
XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY=wayland-test DISPLAY= \
  HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
  KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
  KANSHI_OUT="$T/kanshi.conf" \
  HWDP_DRM="$T/drm" \
  HWDP_PROVIDER_ROOT="$T/no-providers" \
  HWDP_MACHINE_PROVIDERS="$T/no-providers" \
  HWDP_HOOK_ROOT="$T/hooks" HWDP_MACHINE_HOOKS="$T/no-machine-hooks" \
  WAYFIRE_CONFIG_FILE="$T/wayfire.ini" HWDP_WATCH_DAEMONIZED=1 \
  HWDP_HOTPLUG_POLL=1 \
  PATH="$T/bin:$PATH" "$MGR" watch >"$T/mgr.log" 2>&1 &
_mgr=$!
trap 'kill "$_mgr" 2>/dev/null; rm -rf "$T"' EXIT INT TERM

_runs() { [ -f "$T/changed.log" ] && wc -l < "$T/changed.log" || echo 0; }
_wait_runs() {   # <target> <seconds>: poll rather than sleep a fixed time
  _i=0; _lim=$(( ${2:-10} * 4 ))
  while [ "$_i" -lt "$_lim" ]; do
    [ "$(_runs)" -ge "$1" ] && return 0
    sleep 0.25; _i=$((_i + 1))
  done
  return 1
}

# Startup fires `changed` once by design.
_wait_runs 1 10 || fail "no startup pass: $(cat "$T/mgr.log" 2>/dev/null)"
kill -0 "$_mgr" 2>/dev/null \
  || fail "supervisor died early: $(cat "$T/mgr.log" 2>/dev/null)"

# --- quiet means QUIET ------------------------------------------------------
# The poller must fire on a CHANGE, not on every tick. A poller that nudged
# each interval would restart kanshi and re-run every hook a few times a
# minute, forever -- worse than the gap it closes.
_before=$(_runs)
sleep 3                      # three poll intervals with nothing changing
[ "$(_runs)" -eq "$_before" ] \
  || fail "the poller fired with no display change ($_before -> $(_runs))"

# --- plugging a monitor IN fires, and REGENERATES ---------------------------
# The regeneration is the whole point: kanshi's config lists the outputs that
# existed when it was written, so a HUP alone would reload a file that does not
# mention the new panel.
[ -f "$T/kanshi.conf" ] \
  || fail "no runtime config at startup; the regeneration check would be moot"
_cfg_before=$(cksum < "$T/kanshi.conf")
panel DP-2 edid-two 3840x2160
_wait_runs $((_before + 1)) 15 \
  || fail "plugging a panel in fired no changed pass: $(cat "$T/mgr.log")"
grep -q 'display set changed' "$T/mgr.log" \
  || fail "the hotplug was not announced: $(cat "$T/mgr.log")"
sleep 1
[ "$(cksum < "$T/kanshi.conf")" != "$_cfg_before" ] \
  || fail "the kanshi config was not regenerated for the new panel"
grep -q "$(head -1 "$T/drm/card0-DP-2/modes" | cut -dx -f1)" "$T/kanshi.conf" \
  || fail "the regenerated config does not mention the new panel"

# --- and unplugging fires too -----------------------------------------------
# Removal matters as much as arrival: a layout still describing a departed
# panel is what leaves windows stranded off-screen.
_before=$(_runs)
rm -rf "$T/drm/card0-DP-2"
_wait_runs $((_before + 1)) 15 \
  || fail "unplugging a panel fired no changed pass"

# --- a monitor SWAPPED on one connector counts as a change ------------------
# Status alone would miss this: the connector never leaves `connected`. The
# fingerprint is probe_panels, the same source `hwdp id` hashes, so anything
# that changes the display-profile id also triggers the re-layout.
_before=$(_runs)
printf '%s' edid-replacement > "$T/drm/card0-DP-1/edid"
_wait_runs $((_before + 1)) 15 \
  || fail "swapping the monitor on a connector fired no changed pass"

# The supervisor must still own no zombies -- the poller is a tracked child and
# a mis-handled one would be reaped nowhere (mgr.t's lesson, same shape).
_z=$(ps -eo ppid=,state= 2>/dev/null \
     | awk -v p="$_mgr" '$1 == p && $2 ~ /^Z/' | wc -l)
[ "$_z" -eq 0 ] || fail "supervisor left $_z zombie child(ren)"

kill "$_mgr" 2>/dev/null
pass "hotplug: in, out, swapped, and quiet when nothing moves"
