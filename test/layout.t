#!/bin/sh
# layout.t - the kanshi adapter, stub-driven. A fake DRM tree ($DRM/<conn>/
# {status,edid}) drives the HWDP (hardware display profile id; headless, SSOT
# the greeter + kanshi + drift-check all key on); a fake wlr-randr drives the
# session-side geometry (capture/emit/shape). Asserts HWDP is a stable 12-hex
# id that excludes disconnected connectors and tracks the connected set, that
# `capture` writes a scale-free profile named by it, and that `emit` selects a
# matching profile (injecting scale) or synthesizes when none exists.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init layout

KA=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/profiles" "$T/home"

# fake wlr-randr: two Dell portrait panels (session-side geometry for capture/
# emit/shape; the HWDP is a DRM read, so it does not come from here).
cat > "$T/bin/wlr-randr" <<'EOF'
#!/bin/sh
emit_dp1() {
  cat <<'BLK'
DP-1 "Dell Inc. AW2725Q AAA111 (DP-1)"
  Make: Dell Inc.
  Model: AW2725Q
  Serial: AAA111
  Physical size: 590x330 mm
  Enabled: yes
  Modes:
    3840x2160 px, 119.879997 Hz (current)
  Position: 0,0
  Transform: 90
  Scale: 1.000000
BLK
}
emit_dp2() {
  cat <<'BLK'
DP-2 "Dell Inc. AW2725Q BBB222 (DP-2)"
  Make: Dell Inc.
  Model: AW2725Q
  Serial: BBB222
  Physical size: 590x330 mm
  Enabled: yes
  Modes:
    3840x2160 px, 119.879997 Hz (current)
  Position: 2160,0
  Transform: 270
  Scale: 1.000000
BLK
}
emit_dp3() {
  cat <<'BLK'
DP-3 "Dell Inc. AW2725Q CCC333 (DP-3)"
  Make: Dell Inc.
  Model: AW2725Q
  Serial: CCC333
  Physical size: 590x330 mm
  Enabled: yes
  Modes:
    3840x2160 px, 119.879997 Hz (current)
  Position: 4320,0
  Transform: 90
  Scale: 1.000000
BLK
}
emit_dp1; emit_dp2
[ -n "${STUB3:-}" ] && emit_dp3   # a third panel makes it a >=3 wall
EOF
chmod +x "$T/bin/wlr-randr"

# fake DRM tree: the HWDP reads $DRM/<conn>/{status,edid}, NOT wlr-randr,
# so it resolves headless. Two connected panels + one DISCONNECTED (excluded).
# status gates connectedness (sysfs stat size is 0, so the code cannot use
# `[ -s edid ]`); the edid bytes are what get hashed.
mk_conn() {   # <name> <status> [edid-bytes]
  mkdir -p "$T/drm/$1"
  printf '%s' "$2" > "$T/drm/$1/status"
  printf '%s' "${3:-}" > "$T/drm/$1/edid"
}
mk_conn card1-eDP-1 connected    EDID-PANEL-A
mk_conn card1-DP-1  connected    EDID-PANEL-B
mk_conn card1-DP-2  disconnected ''

run() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY=wayland-test HWDP_MACHINE_PROVIDERS="$T/no-machine" \
    KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
    KANSHI_OUT="$T/out" HWDP_DRM="$T/drm" \
    ${STUB3:+STUB3="$STUB3"} ${LODPI_MAX_W:+LODPI_MAX_W="$LODPI_MAX_W"} \
    sh "$KA" "$@"
}

# --- HWDP: 12 hex, stable, excludes disconnected, tracks the set -------------
hwdp=$(run id)
case "$hwdp" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) fail "hwdp not hex: '$hwdp'" ;;
esac
[ "${#hwdp}" = 12 ] || fail "hwdp not 12 chars: '$hwdp'"
[ "$(run id)" = "$hwdp" ] || fail "hwdp not stable across runs"
# a disconnected connector must not contribute: plugging it (status->connected,
# real edid) changes the id; unplugging restores it.
printf connected > "$T/drm/card1-DP-2/status"
printf 'EDID-PANEL-C' > "$T/drm/card1-DP-2/edid"
[ "$(run id)" != "$hwdp" ] \
  || fail "hwdp ignored a newly-connected panel"
printf disconnected > "$T/drm/card1-DP-2/status"
[ "$(run id)" = "$hwdp" ] \
  || fail "hwdp did not exclude the disconnected panel"

# --- capture: writes profiles/<hwdp>.conf, scale-free, both panels -----------
out=$(run capture)
[ "$out" = "$T/profiles/$hwdp.conf" ] || fail "capture wrote wrong path: $out"
grep -q "profile hwdp-$hwdp" "$out" || fail "captured profile not named by hwdp"
grep -q 'AW2725Q AAA111' "$out" || fail "captured profile missing panel 1"
grep -q 'AW2725Q BBB222' "$out" || fail "captured profile missing panel 2"
grep -q 'transform 270' "$out" || fail "captured profile lost a transform"

# --- capture never destroys a profile silently -------------------------------
# The file invites hand-editing (its own comments say so), and capture used to
# `> $dst`, truncating BEFORE it built the replacement: a re-capture threw the
# edits away, and a failure part-way left a corrupt file with no original.
#
# Re-capturing an UNCHANGED rig is a no-op: same bytes, and the file is not
# rewritten at all, so even its mtime stands.
_sum=$(cksum < "$out")
_before=$(stat -c %Y "$out")
sleep 1
out2=$(run capture)
[ "$out2" = "$out" ] || fail "re-capture wrote a different path"
[ "$(cksum < "$out")" = "$_sum" ] || fail "an unchanged re-capture rewrote it"
[ "$(stat -c %Y "$out")" = "$_before" ] \
  || fail "an unchanged re-capture touched the profile"
[ -e "$out.bak" ] && fail "an unchanged re-capture made a needless backup" || :

# When the file DOES differ from what capture would write -- a hand edit is the
# case that matters -- the old one is kept and the overwrite is announced.
# Editing the file is the direct way to reach that branch; it needs no stub
# gymnastics, and a hand edit is literally the thing being protected.
printf '# my own notes\n' >> "$out"
_edited=$(cksum < "$out")
out3=$(run capture 2>"$T/cap.err") || fail "re-capture over an edit errored"
[ "$out3" = "$out" ] || fail "re-capture wrote a different path"
[ -f "$out.bak" ] || fail "capture destroyed a hand-edited profile"
[ "$(cksum < "$out.bak")" = "$_edited" ] \
  || fail "the backup is not the file that was replaced"
grep -q 'previous profile kept as' "$T/cap.err" \
  || fail "capture overwrote a profile without saying so"
grep -q 'my own notes' "$out" \
  && fail "the edit survived into the new profile" || :
grep -q "profile hwdp-$hwdp" "$out" || fail "the rewritten profile is malformed"

# stdout stays JUST the path: the announcement went to stderr, so a caller
# reading the path still gets one clean line.
[ "$(printf '%s' "$out3" | grep -c .)" -eq 1 ] \
  || fail "capture put more than the path on stdout"
rm -f "$out.bak"
grep -q '^ *output .* scale ' "$out" \
  && fail "captured output line must NOT carry a scale"

# --- emit: selects the matching profile and injects scale --------------------
gen=$(run layout)                            # emit prints the OUT path
grep -q "profile hwdp-$hwdp" "$gen" || fail "emit did not pick the hwdp profile"
grep -q '^ *output .* scale ' "$gen" || fail "emit did not inject a scale"

# --- emit: the injected scale is ALWAYS 1.00 -- NEVER a downscale. Even with a
# design area (5760x3600) LARGER than the 4K panel -- where the RETIRED sqrt
# model gave 0.65 -- scale_for floors at 1, so emit injects 1.00. Proves the
# downscale path is gone (the floor policy; see the fixed-pixel gotcha).
scale_of() {   # <file> <serial> -> the scale on that panel's output line
  grep "$2" "$1" | sed -n 's/.* scale \([0-9.]*\).*/\1/p'
}
emit_ds() {   # large design area: the old sqrt path would have downscaled here
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY=wayland-test HWDP_MACHINE_PROVIDERS="$T/no-machine" \
    KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky-ds" \
    KANSHI_OUT="$T/out-ds" HWDP_DRM="$T/drm" \
    KANSHI_DESIGN_W=5760 KANSHI_DESIGN_H=3600 sh "$KA" layout
}
dsgen=$(emit_ds)
[ "$(scale_of "$dsgen" AAA111)" = 1.00 ] \
  || fail "emit scale != 1.00 -- downscale not retired (got \
'$(scale_of "$dsgen" AAA111)')"
[ "$(scale_of "$dsgen" BBB222)" = 1.00 ] || fail "emit scale != 1.00, panel 2"

# --- resolve stickiness: a hand-edited sticky value SURVIVES a matching output
# signature (override honoured, not clobbered), and a CHANGED signature forces a
# recompute (the panel-swap path). Computed is now 1.00, so a 2.00 override (a
# HiDPI upscale -- the only kind that means anything under the >=1 floor) is
# unmistakably distinct from a recompute. --------------------------------------
tab=$(printf '\t')
edid='Dell Inc. AW2725Q AAA111'
printf '%s%s2.00%s3840x2160@590x330\n' "$edid" "$tab" "$tab" > "$T/sticky"
gen=$(run layout)
[ "$(scale_of "$gen" AAA111)" = 2.00 ] \
  || fail "sticky override not honoured on a matching signature"
printf '%s%s2.00%s9999x9999@1x1\n' "$edid" "$tab" "$tab" > "$T/sticky"
gen=$(run layout)
[ "$(scale_of "$gen" AAA111)" = 1.00 ] \
  || fail "changed signature did not recompute (kept the stale override)"

# --- emit: no matching profile -> synthesize ---------------------------------
rm -f "$T/profiles/$hwdp.conf"
gen=$(run layout)
grep -qi 'no matching layout profile' "$gen" || fail "emit did not synthesize"

# --- shape: <3 panels -> single, >=3 -> triple (the panel-count coarsening) ---
[ "$(run shape)" = single ] || fail "2 panels should be shape 'single'"
[ "$(STUB3=1 run shape)" = triple ] || fail "3 panels should be shape 'triple'"

# --- uiprofile: per-display fonts + lock ring; density + HWDP override --------
# The stub panel is 3840 wide, so it reads hi-res under the default 2560
# threshold; RAISING the threshold makes the SAME panel read low-res, exercising
# the density boundary without a second fake panel.
uphas() { printf '%s\n' "$up" | grep -q "$1"; }

# hidpi: the shrink keys are EMPTY (each app's own config value stands) and
# TITLE_FONT is the hidpi default -- a strict no-op on a hi-res display.
up=$(run ui)
uphas '^KITTY_FONT=$'  || fail "uiprofile hidpi: KITTY_FONT should be empty"
uphas '^MAKO_FONT=$'   || fail "uiprofile hidpi: MAKO_FONT should be empty"
uphas '^LOCK_RADIUS=$' || fail "uiprofile hidpi: LOCK_RADIUS should be empty"
uphas '^TITLE_FONT=.*Semibold' || fail "uiprofile hidpi: TITLE_FONT missing"
# CURSOR_SIZE is ALWAYS set (like TITLE_FONT): the wall default on hidpi, so a
# mode switch back to hi-res restores it.
uphas '^CURSOR_SIZE=48$' || fail "uiprofile hidpi: CURSOR_SIZE should be 48"

# lodpi (same panel, threshold above its width): every shrink key is non-empty.
up=$(LODPI_MAX_W=5000 run ui)
uphas '^KITTY_FONT=[0-9]'  || fail "uiprofile lodpi: KITTY_FONT unset"
uphas '^MAKO_FONT=..*'     || fail "uiprofile lodpi: MAKO_FONT unset"
uphas '^LOCK_RADIUS=[0-9]' || fail "uiprofile lodpi: LOCK_RADIUS unset"
uphas '^CURSOR_SIZE=32$'   || fail "uiprofile lodpi: CURSOR_SIZE should be 32"

# a >=3 wall is hidpi even below the width threshold (the shape gate wins).
up=$(STUB3=1 LODPI_MAX_W=5000 run ui)
uphas '^KITTY_FONT=$' || fail "uiprofile: a 3-panel wall must resolve hidpi"

# HWDP override wins PER KEY, read LITERALLY (a value with spaces, no quoting);
# an absent key falls through to the density default.
printf 'KITTY_FONT=13\nTITLE_FONT=Custom Face 12\n' > "$T/profiles/$hwdp.ui"
up=$(LODPI_MAX_W=5000 run ui)
uphas '^KITTY_FONT=13$' || fail "uiprofile: HWDP override KITTY_FONT ignored"
uphas '^TITLE_FONT=Custom Face 12$' \
  || fail "uiprofile: HWDP override TITLE_FONT (spaces) not read literally"
uphas '^MAKO_FONT=..*' || fail "uiprofile: override dropped the MAKO default"
rm -f "$T/profiles/$hwdp.ui"

pass
