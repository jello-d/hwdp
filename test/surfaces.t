#!/bin/sh
# surfaces.t - `hwdp surfaces`: named parts of panels, resolved against what
# is switched on, in the compositor's own logical pixels.
#
# The desk is the dock target: a laptop panel (which can be switched off), a
# 4K PORTRAIT (rotated, so its logical size is 2160x3840 at scale 1) and a 4K
# landscape. The cases are the contract usher relies on:
#   - a half of a ROTATED panel resolves on the right axis and at the scale
#     in force, so a fraction survives a scale change where a rect would not;
#   - a surface on a switched-off panel is left out, and says so;
#   - no file is silence (a soft dependency), but a BROKEN file is refused
#     whole, because a half-right map seeds windows into the wrong places;
#   - without a session it says it needs one, rather than guessing.
. "$(dirname "$0")/harness_lib"
harness_init surfaces

KA=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/drm" "$T/surf"

cat > "$T/bin/wlr-randr" <<'EOF'
#!/bin/sh
_out() {   # <conn> <make> <model> <serial> <w> <h> <x> <tr> <scale> <en>
  cat <<BLK
$1 "$2 $3 $4 ($1)"
  Make: $2
  Model: $3
  Serial: $4
  Physical size: 600x340 mm
  Enabled: ${10}
  Modes:
    ${5}x${6} px, 60.000000 Hz (preferred, current)
  Position: $7,0
  Transform: $8
  Scale: $9
BLK
}
_out eDP-1 Acme LAPTOP SN1 2880 1800 0 normal 1.000000 "${LAPTOP_ON:-yes}"
_out DP-1 Dell PORTRAIT SN2 3840 2160 2880 90 "${PORTRAIT_SCALE:-1.000000}" yes
_out DP-2 Dell WIDE SN3 3840 2160 5040 normal 1.000000 yes
EOF
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
    LAPTOP_ON="${LAPTOP_ON:-yes}" \
    PORTRAIT_SCALE="${PORTRAIT_SCALE:-1.000000}" \
    sh "$KA" surfaces "$@"
}
_id=$(env -i PATH="$T/bin:/usr/bin:/bin" HWDP_DRM="$T/drm" \
  HWDP_MACHINE_PROVIDERS="$T/no-machine" sh "$KA" id)
[ -n "$_id" ] || fail "no hwdp id from the stub desk"
F=$T/surf/$_id.conf

# --- no file: silence, status 0 -----------------------------------------------
_o=$(run 2>&1) || fail "no surfaces file must exit 0"
[ -z "$_o" ] || fail "no surfaces file must print nothing: '$_o'"
pass "no file is silence (a soft dependency)"

# --- the desk -----------------------------------------------------------------
cat > "$F" <<'EOF'
# the dock target
surface comms "Dell PORTRAIT SN2" cell 0 0 bottom
surface mail  "Dell PORTRAIT SN2" cell 0 0 top
surface code  "Dell WIDE SN3"     cell 1 0
surface ref   "Acme LAPTOP SN1"   cell 2 1 right
EOF
_o=$(run 2>"$T/err") || fail "a valid file failed: $(cat "$T/err")"
_line() { printf '%s\n' "$_o" | awk -v s="$1" '$1 == s'; }
[ "$(_line comms)" = "comms DP-1 0 0 0 1920 2160 1920" ] \
  || fail "bottom half of a rotated 4K: '$(_line comms)'"
[ "$(_line mail)" = "mail DP-1 0 0 0 0 2160 1920" ] \
  || fail "top half of a rotated 4K: '$(_line mail)'"
[ "$(_line code)" = "code DP-2 1 0 0 0 3840 2160" ] \
  || fail "a whole landscape panel: '$(_line code)'"
[ "$(_line ref)" = "ref eDP-1 2 1 1440 0 1440 1800" ] \
  || fail "the right half of the laptop, cell 2 1: '$(_line ref)'"
[ -s "$T/err" ] && fail "a clean file must say nothing on stderr: \
$(cat "$T/err")"
pass "halves of a ROTATED panel, a whole panel, cells passed through"

# --- a fraction follows the scale ---------------------------------------------
# The same portrait at 1.25 is 1728x3072, so its bottom half is 1728x1536 at
# y=1536. A rect written by hand would now be wrong; a fraction cannot be.
_o=$(PORTRAIT_SCALE=1.250000 run 2>/dev/null) || fail "rescaled run failed"
[ "$(_line comms)" = "comms DP-1 0 0 0 1536 1728 1536" ] \
  || fail "the bottom half at 1.25: '$(_line comms)'"
pass "a region follows the scale in force"

# --- a switched-off panel is left out, and named ------------------------------
_o=$(LAPTOP_ON=no run 2>"$T/err") || fail "a switched-off panel failed the run"
[ -z "$(_line ref)" ] || fail "a surface on a switched-off panel was emitted"
[ -n "$(_line code)" ] || fail "the other surfaces must still come out"
grep -q '`ref`: "Acme LAPTOP SN1" is attached but switched off' "$T/err" \
  || fail "the skip must be named on stderr: $(cat "$T/err")"
pass "a switched-off panel is skipped, and said so"

# --- --check: words, notes, and a panel nobody uses ---------------------------
printf 'surface ghost "Nope MISSING SN9" cell 0 0\n' >> "$F"
_c=$(run --check) || fail "--check on a sound file must exit 0"
printf '%s\n' "$_c" | grep -q '^ok    comms .*DP-1, bottom half of Dell' \
  || fail "--check must describe each surface: $_c"
printf '%s\n' "$_c" | grep -q 'ghost.*no attached panel is named' \
  || fail "--check must flag a panel that matches nothing: $_c"
pass "--check describes each surface and flags a name matching nothing"

# --- a BROKEN file is refused whole -------------------------------------------
_refuse() {   # <label> <line to add> <expected stderr fragment>
  cp "$F" "$F.good"
  printf '%s\n' "$2" >> "$F"
  # The status is read in the ELSE branch: after an `if` whose condition
  # failed and which has no else, $? is the if's own 0, not the command's.
  if _o=$(run 2>"$T/err"); then
    mv "$F.good" "$F"; fail "$1: accepted"
  else
    _rc=$?
  fi
  mv "$F.good" "$F"
  [ "$_rc" -eq 2 ] || fail "$1: exit $_rc, expected 2"
  [ -z "$_o" ] || fail "$1: a refused file must print NOTHING: '$_o'"
  grep -q "$3" "$T/err" || fail "$1: no '$3' in: $(cat "$T/err")"
}
_refuse "a name used twice" 'surface code "Dell WIDE SN3" cell 3 3' \
  'surface `code` is defined twice'
_refuse "a full panel over a half" 'surface all "Dell PORTRAIT SN2" cell 0 0' \
  'claim the same part of "Dell PORTRAIT SN2" in cell 0 0'
_refuse "an unknown region" 'surface m "Dell WIDE SN3" cell 0 0 middle' \
  'region `middle` is not one of'
_refuse "an unquoted panel" 'surface m Dell cell 0 0' \
  'the panel must be a quoted EDID name'
_refuse "not a surface line" 'surfaces m "Dell WIDE SN3" cell 0 0' \
  'expected `surface <name>'
# Opposite halves in one cell are NOT a clash (comms + mail above prove it);
# the same half in a DIFFERENT cell is not either.
printf 'surface late "Dell PORTRAIT SN2" cell 5 5 bottom\n' >> "$F"
run >/dev/null 2>&1 || fail "the same half in another cell is not a clash"
pass "a broken file is refused whole, naming the line and the problem"

# --- no session: say so, do not guess -----------------------------------------
_o=$(WL= run 2>"$T/err") && fail "surfaces with no session must not succeed"
_rc=$?
[ "$_rc" -eq 3 ] || fail "no session: exit $_rc, expected 3"
grep -q 'need a session' "$T/err" || fail "no session: $(cat "$T/err")"
pass "without a session it says so (exit 3)"

# --- --write: the one writer of the file --------------------------------------
# Connectors in, EDID names out; lines for a panel that is not switched on now
# survive; the old file goes to the STATE dir; a broken result is refused
# whole with the file untouched; no temp dir is left behind.
wr() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY="${WL-wayland-test}" \
    HWDP_MACHINE_PROVIDERS="$T/no-machine" HWDP_PROVIDER_ROOT="$T/no-user" \
    HWDP_DRM="$T/drm" XDG_RUNTIME_DIR="$T/run" HWDP_SURFACES="$T/surf" \
    LAPTOP_ON="${LAPTOP_ON:-yes}" sh "$KA" surfaces --write
}
# The stub desk is a laptop panel beside externals, so --write files it under
# the DESK id; the hand-written $F above is the exact-id (legacy) path.
FD=$T/surf/$(env -i PATH="$T/bin:/usr/bin:/bin" HWDP_DRM="$T/drm" \
  HWDP_MACHINE_PROVIDERS="$T/no-machine" sh "$KA" id --desk).conf
rm -f "$FD"
printf 'surface comms DP-1 cell 0 0 bottom\nsurface code DP-2 cell 1 0\n' \
  | wr >/dev/null || fail "--write refused valid lines"
grep -qx 'surface comms "Dell PORTRAIT SN2" cell 0 0 bottom' "$FD" \
  || fail "--write must name the panel by EDID: $(cat "$FD")"
_o=$(run 2>/dev/null)
[ "$(_line comms)" = "comms DP-1 0 0 0 1920 2160 1920" ] \
  || fail "the written file does not resolve: $(_line comms)"
printf 'surface away "Nope ELSEWHERE SN8" cell 3 3 top\n' >> "$FD"
printf 'surface code DP-2 cell 1 0\n' | wr >/dev/null \
  || fail "a rewrite failed"
grep -q '^surface away "Nope ELSEWHERE SN8" cell 3 3 top$' "$FD" \
  || fail "a panel not switched on lost its surface in a rewrite"
grep -q comms "$FD" && fail "a rewrite must REPLACE the switched-on panels"
[ -f "$T/home/.local/state/hwdp/surfaces/$(basename "$FD").bak" ] \
  || fail "the old file must be kept in the state dir"
_before=$(cksum < "$FD")
if printf 'surface a DP-2 cell 0 0\nsurface b DP-2 cell 0 0 top\n' \
    | wr >/dev/null 2>"$T/err"; then fail "--write accepted a clash"
else _rc=$?; fi
[ "$_rc" -eq 2 ] && [ "$(cksum < "$FD")" = "$_before" ] \
  || fail "a broken result must be exit 2 and leave the file alone"
grep -q 'NOT written' "$T/err" || fail "the refusal must say so"
if printf 'surface a DP-9 cell 0 0\n' | wr >/dev/null 2>&1; then
  fail "--write accepted an unknown output"
fi
ls -A "$T/surf" | grep -q '^\.write' && fail "a temp dir was left behind"
pass "--write: resolves, keeps the unseen, backs up, refuses whole"
