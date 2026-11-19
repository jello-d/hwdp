#!/bin/sh
# map.t - `hwdp map` draws the desk in text: the switched-on outputs where the
# compositor has them, their surfaces, the shape, and any problem with the
# arrangement. A report, so the assertions are about what a reader must be
# able to SEE: every output and surface named, nothing wider than asked, a
# broken surfaces file reported rather than half drawn, a gap called out.
. "$(dirname "$0")/harness_lib"
harness_init map

KA=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/drm" "$T/surf"

# The dock target: laptop, a 4K rotated to portrait, a 4K landscape. DP2_X
# moves the landscape (5040 packs it against the portrait).
cat > "$T/bin/wlr-randr" <<'STUB'
#!/bin/sh
_out() {   # <conn> <w> <h> <x> <transform>
  cat <<BLK
$1 "Acme MODEL SN-$1 ($1)"
  Make: Acme
  Model: MODEL
  Serial: SN-$1
  Physical size: 600x340 mm
  Enabled: yes
  Modes:
    ${2}x${3} px, 60.000000 Hz (preferred, current)
  Position: $4,0
  Transform: $5
  Scale: 1.000000
BLK
}
_out eDP-1 2880 1800 0 normal
_out DP-1 3840 2160 2880 90
_out DP-2 3840 2160 "${DP2_X:-5040}" normal
STUB
chmod +x "$T/bin/wlr-randr"
for _c in eDP-1 DP-1 DP-2; do
  mkdir -p "$T/drm/card1-$_c"
  printf connected > "$T/drm/card1-$_c/status"
  printf 'EDID-%s' "$_c" > "$T/drm/card1-$_c/edid"
done

run() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY="${WL-wayland-test}" \
    HWDP_MACHINE_PROVIDERS="$T/no-machine" HWDP_PROVIDER_ROOT="$T/no-user" \
    HWDP_DRM="$T/drm" XDG_RUNTIME_DIR="$T/run" HWDP_SURFACES="$T/surf" \
    DP2_X="${DP2_X:-5040}" \
    sh "$KA" map "$@"
}
_id=$(env -i PATH="$T/bin:/usr/bin:/bin" HWDP_DRM="$T/drm" \
  HWDP_MACHINE_PROVIDERS="$T/no-machine" sh "$KA" id)
_has() {   # <label> <map text> <fixed string>
  printf '%s\n' "$2" | grep -qF -- "$3" || fail "$1: no '$3' in:
$2"
}

# --- the desk, no surfaces ----------------------------------------------------
_m=$(run --width 78) || fail "map failed on a sound desk"
_has "the laptop is drawn" "$_m" "eDP-1 BL"
_has "the rotated 4K is portrait" "$_m" "DP-1 EP"
_has "the landscape is drawn" "$_m" "DP-2 EL"
_has "the legend has the rotated size" "$_m" \
  "DP-1   EP  2160x3840 at 2880,0  Acme MODEL SN-DP-1"
_has "the shape is stated" "$_m" "shape  BL+EL+EP"
_has "no surfaces is said" "$_m" "surfaces  none for this desk"
printf '%s\n' "$_m" | grep -q PROBLEM && fail "a packed desk has no problem"
_long=$(printf '%s\n' "$_m" | sed -n '1,/^$/p' | awk 'length > 78' | wc -l)
[ "$_long" -eq 0 ] || fail "the drawing ran past --width 78"
pass "the outputs, their kind and size, the shape"

# --- surfaces are drawn into their regions ------------------------------------
cat > "$T/surf/$_id.conf" <<'EOF'
surface comms "Acme MODEL SN-DP-1" cell 0 0 bottom
surface mail  "Acme MODEL SN-DP-1" cell 0 0 top
surface code  "Acme MODEL SN-DP-2" cell 1 0 left
EOF
_m=$(run --width 78) || fail "map failed with surfaces"
_has "a bottom-half surface is labelled in the drawing" "$_m" "comms 0,0"
_has "a top-half surface is labelled" "$_m" "mail 0,0"
_has "the half is split with dots" "$_m" "|......"
_has "the legend has the resolved rect" "$_m" \
  "surface comms      DP-1 cell 0,0  2160x1920 at 0,1920"
# comms is the BOTTOM half: its label must sit below mail's.
_lm=$(printf '%s\n' "$_m" | grep -n 'mail 0,0' | head -1 | cut -d: -f1)
_lc=$(printf '%s\n' "$_m" | grep -n 'comms 0,0' | head -1 | cut -d: -f1)
[ "$_lc" -gt "$_lm" ] || fail "the bottom-half label is not below the top"
pass "surfaces drawn into their halves, and listed with their rects"

# --- a CUT panel: its divider even when empty, and the legend says so --------
# The landscape is cut left-right in cell 1 1 with nothing in it, and the
# portrait's top-bottom cut in 0 0 (implied by comms and mail) is full. Both
# divide their panel; only the empty one names an empty half.
mkdir -p "$T/home/.config/hwdp/desks"
_dk=$(env -i PATH="$T/bin:/usr/bin:/bin" HWDP_DRM="$T/drm" \
  HWDP_MACHINE_PROVIDERS="$T/no-machine" sh "$KA" id --desk)
{ cat "$T/surf/$_id.conf"
  printf 'split "Acme MODEL SN-DP-1" cell 0 0 top-bottom\n'
  printf 'split "Acme MODEL SN-DP-2" cell 1 1 left-right\n'
} > "$T/home/.config/hwdp/desks/$_dk.conf"
_m=$(run --width 78) || fail "map failed with splits"
_has "an empty cut is listed with both halves empty" "$_m" \
  "split   left-right DP-2 cell 1,1  left and right empty"
_has "a full cut is listed with nothing empty" "$_m" \
  "split   top-bottom DP-1 cell 0,0"
printf '%s\n' "$_m" | grep -q 'DP-1 cell 0,0 .*empty' \
  && fail "a cut with both halves placed is not empty: $_m"
printf '%s\n' "$_m" | grep -q 'DP-2 cell 1,0 .*empty' \
  && fail "an implied cut (code, cell 1 0) is not a written one: $_m"
# DP-2 is cut twice over (code's left half in 1 0, the empty cut in 1 1):
# one divider column, drawn once, which the surfaces alone also draw. Take
# the cut away and the drawing must lose nothing else: the same picture.
_with=$(printf '%s\n' "$_m" | sed -n '1,/^$/p')
sed -i '/cell 1 1 left-right/d' "$T/home/.config/hwdp/desks/$_dk.conf"
_without=$(run --width 78 | sed -n '1,/^$/p')
[ "$_with" = "$_without" ] \
  || fail "a cut on a panel already divided must not change the picture"
sed -i '/^surface code/d' "$T/home/.config/hwdp/desks/$_dk.conf"
printf 'split "Acme MODEL SN-DP-2" cell 1 1 left-right\n' \
  >> "$T/home/.config/hwdp/desks/$_dk.conf"
_m=$(run --width 78)
_cut=$(printf '%s\n' "$_m" | sed -n '1,/^$/p' | grep -c ':')
[ "$_cut" -gt 0 ] || fail "an EMPTY cut must draw its divider: $_m"
rm -f "$T/home/.config/hwdp/desks/$_dk.conf"
pass "a cut panel is divided even when empty, and the legend names it"

# --- the GRID: the desk in every cell, that cell's surfaces, the default -----
cat > "$T/home/.config/hwdp/desks/$_dk.conf" <<'EOF'
grid 3 2
surface comms "Acme MODEL SN-DP-1" cell 0 0 bottom
surface mail  "Acme MODEL SN-DP-1" cell 0 0 top
surface code  "Acme MODEL SN-DP-2" cell 1 0 left
surface chat  "@builtin" cell 2 1
default overflow "@builtin" top
EOF
printf '%s\n' 'comms Comms' 'mail Mail' 'code Code' 'chat Chat' \
  'overflow Overflow' > "$T/home/.config/hwdp/surfaces.names"
_m=$(run --width 78) || fail "map failed with a grid"
_g=$(printf '%s\n' "$_m" | sed -n '/^GRID/,/^shape/p')
_has "the grid is drawn, its size said" "$_g" "GRID 3x2"
for _c in 0,0 1,0 2,0 0,1 1,1 2,1; do
  _has "cell $_c is drawn" "$_g" "- $_c -"
done
# One cell's box: its title line to the blank line after it.
_cell() { printf '%s\n' "$_g" | awk -v c="- $1 -" '
  index($0, c) { p = 1; o = index($0, c) - 2 }
  p && /^$/ { exit }
  p { print substr($0, o, 38) }'; }
_has "a cell holds its own surface" "$(_cell 0,0)" "comms"
_has "both halves of a cut" "$(_cell 0,0)" "mail"
_cell 1,0 | grep -q 'comms\|mail' && fail "a cell drew another cell's surface:
$(_cell 1,0)"
_has "the default shows where a cell leaves its place empty" "$(_cell 1,1)" \
  "(overflow)"
_cell 2,1 | grep -q '(overflow)' && fail "the default drawn where a surface
covers its place: $(_cell 2,1)"
_has "chat is in its cell" "$(_cell 2,1)" "chat"
# A cell clipped at the width loses its right edge: every box must close.
_open=$(printf '%s\n' "$_g" | awk '/^\+- / && !/\+$/' | wc -l)
[ "$_open" -eq 0 ] || fail "a cell was cut off at the width:
$_g"
# The drawing's own lines, as above for the desk (the note under it is prose).
_long=$(printf '%s\n' "$_g" | awk '/^[+|]/ && length > 78' | wc -l)
[ "$_long" -eq 0 ] || fail "the grid ran past --width 78"
_g40=$(run --width 40 | sed -n '/^GRID/,/^shape/p')
_long=$(printf '%s\n' "$_g40" | awk '/^[+|]/ && length > 40' | wc -l)
[ "$_long" -eq 0 ] || fail "the grid ran past --width 40"
_has "narrow, it still draws every cell" "$_g40" "- 2,1 -"
_open=$(printf '%s\n' "$_g40" | awk '/^\+- / && !/\+$/' | wc -l)
[ "$_open" -eq 0 ] || fail "narrow, a cell was cut off at the width"
rm -f "$T/home/.config/hwdp/desks/$_dk.conf" \
  "$T/home/.config/hwdp/surfaces.names"
mv "$T/surf/$_id.conf" "$T/surf.keep"     # the earlier section's surfaces
_m=$(run --width 78)
mv "$T/surf.keep" "$T/surf/$_id.conf"
printf '%s\n' "$_m" | grep -q '^GRID' && fail "a desk with no surfaces drew
a grid: $_m"
pass "the grid: each cell its own surfaces, the default where it falls"

# --- a BROKEN surfaces file is reported, never half drawn ---------------------
printf 'surface code "Acme MODEL SN-DP-2" cell 9 9\n' >> "$T/surf/$_id.conf"
printf 'split "Acme MODEL SN-DP-2" cell 1 1 left-right\n' \
  >> "$T/surf/$_id.conf"
_m=$(run --width 78) || fail "map must still draw with a broken surfaces file"
_has "a broken file is reported" "$_m" "surfaces  BROKEN, not drawn"
printf '%s\n' "$_m" | grep -q 'comms 0,0' \
  && fail "a broken surfaces file must not be drawn at all"
{ printf '%s\n' "$_m" | grep -q '^  split' \
  || printf '%s\n' "$_m" | sed -n '1,/^$/p' | grep -q ':'; } \
  && fail "a broken file's cut must not be drawn either: $_m"
_has "the outputs are still drawn" "$_m" "DP-1 EP"
rm -f "$T/surf/$_id.conf"
pass "a broken surfaces file is reported and not drawn"

# --- a gap is a PROBLEM -------------------------------------------------------
_m=$(DP2_X=5100 run --width 78) || fail "map failed on a gapped desk"
_has "the gap is reported" "$_m" "PROBLEM  DP-2 does not touch DP-1: 60px"
pass "a gap in the arrangement is called out"

# --- width, arguments, and no session -----------------------------------------
_m=$(run --width 40) || fail "map failed at width 40"
_long=$(printf '%s\n' "$_m" | sed -n '1,/^$/p' | awk 'length > 40' | wc -l)
[ "$_long" -eq 0 ] || fail "the drawing ran past --width 40"
run --width wide >/dev/null 2>&1 && fail "a non-numeric width was accepted"
run --nonsense >/dev/null 2>&1 && fail "an unknown argument was accepted"
if WL= run >/dev/null 2>"$T/err"; then
  fail "map with no session must not succeed"
else
  _rc=$?
fi
[ "$_rc" -eq 3 ] || fail "no session: exit $_rc, expected 3"
grep -q 'needs a session' "$T/err" || fail "no session: $(cat "$T/err")"
pass "width is honoured, bad arguments refused, no session says so"
