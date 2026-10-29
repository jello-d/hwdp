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

# --- a BROKEN surfaces file is reported, never half drawn ---------------------
printf 'surface code "Acme MODEL SN-DP-2" cell 9 9\n' >> "$T/surf/$_id.conf"
_m=$(run --width 78) || fail "map must still draw with a broken surfaces file"
_has "a broken file is reported" "$_m" "surfaces  BROKEN, not drawn"
printf '%s\n' "$_m" | grep -q 'comms 0,0' \
  && fail "a broken surfaces file must not be drawn at all"
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
