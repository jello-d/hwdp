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
    HWDP_DESKS="$T/desks" \
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
  'expected `grid`, `surface` or `default`'
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
    HWDP_DESKS="$T/desks" \
    LAPTOP_ON="${LAPTOP_ON:-yes}" sh "$KA" surfaces --write
}
# The stub desk is a laptop panel beside externals, so --write files it under
# the DESK id, in the DESKS dir; the hand-written $F above is the exact-id
# path from before desk files, still read when there is no desk file.
FD=$T/desks/$(env -i PATH="$T/bin:/usr/bin:/bin" HWDP_DRM="$T/drm" \
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
ls -A "$T/desks" | grep -q '^\.write' && fail "a temp dir was left behind"
pass "--write: resolves, keeps the unseen, backs up, refuses whole"

# --- desk files: names, grid, default, and the R7 map -------------------------
# The plain record is FROZEN at eight fields (usher refuses a map whole on any
# other count), so everything new is --map, --grid, --names and --check.
NM=$T/desks/surfaces.names      # the names list lives IN the desks dir
rm -rf "$T/desks"; mkdir -p "$T/desks"
printf '%s\n' 'comms Work Comms' 'code' 'elsewhere Elsewhere' 'spare' > "$NM"
_pid() { env -i PATH="$T/bin:/usr/bin:/bin" HWDP_DRM="$T/drm" \
  HWDP_MACHINE_PROVIDERS="$T/no-machine" sh "$KA" id --panels \
  | awk -v c="$1" '$1 == c { print $2 }'; }
cat > "$FD" <<'DESK'
grid 3 2
surface comms "Dell PORTRAIT SN2" cell 0 0 bottom
surface code  "Dell WIDE SN3"     cell 1 0
default elsewhere "@builtin"
DESK
_o=$(run 2>&1) || fail "a desk file must resolve: $_o"
[ "$(printf '%s\n' "$_o" | awk 'NF != 8' | wc -l)" -eq 0 ] \
  && [ "$(printf '%s\n' "$_o" | wc -l)" -eq 2 ] \
  || fail "the plain record must stay 8 fields, no default line: $_o"
_o=$(run --map 2>&1) || fail "--map failed: $_o"
_want="comms DP-1 0 0 0 1920 2160 1920 $(_pid DP-1) 0 0.5 1 0.5
code DP-2 1 0 0 0 3840 2160 $(_pid DP-2) 0 0 1 1
elsewhere eDP-1 * * 0 0 2880 1800 $(_pid eDP-1) 0 0 1 1"
[ "$_o" = "$_want" ] || fail "--map: expected
$_want
got
$_o"
[ "$(run --grid)" = "3 2" ] || fail "--grid: $(run --grid)"
[ "$(run --names | sed -n 1p)" = "comms Work Comms" ] \
  && [ "$(run --names | sed -n 2p)" = "code code" ] \
  || fail "--names: a label defaults to the name: $(run --names)"
run --check 2>&1 | grep -q '`spare` is not placed at this desk' \
  || fail "--check must name an unplaced name: $(run --check 2>&1)"
pass "--map: panel id and fractions appended, the default as * *; plain frozen"

_refused() {   # <label> <line to add> <stderr text>
  cp "$FD" "$T/desk.keep"; printf '%s\n' "$2" >> "$FD"
  _o=$(run 2>"$T/err") && fail "$1: accepted"
  _rc=$?; [ "$_rc" -eq 2 ] && [ -z "$_o" ] \
    || fail "$1: must be exit 2 with nothing on stdout (rc=$_rc)"
  grep -q "$3" "$T/err" || fail "$1: no '$3' in: $(cat "$T/err")"
  cp "$T/desk.keep" "$FD"
}
_refused "a name not in the names file" \
  'surface typo "Dell WIDE SN3" cell 2 0' 'not in the names file'
_refused "a cell outside the grid" \
  'surface spare "Dell WIDE SN3" cell 3 0' 'outside the grid'
_refused "a name both placed and the default" \
  'surface elsewhere "Dell WIDE SN3" cell 2 0' 'both a surface and'
pass "a desk file is refused whole for an unlisted name or an off-grid cell"

grep -v '^default' "$FD" > "$T/nodef"; cp "$T/nodef" "$FD"
run --check 2>&1 | grep -q 'a gap in the map' \
  || fail "--check must flag gaps with no default: $(run --check 2>&1)"
pass "with no default, --check names the gaps in the map"

# A GENERIC desk, found by the desk's KIND when it has no file of its own,
# with the built-in named by its role. A laptop on its own: its own DRM
# view, and wlr-randr told to show only the built-in.
rm -f "$FD"
mkdir -p "$T/drm-laptop/card1-eDP-1"
printf connected > "$T/drm-laptop/card1-eDP-1/status"
printf 'EDID-eDP-1' > "$T/drm-laptop/card1-eDP-1/edid"
sed -i 's/^_out DP-/[ -n "${ONLY_LAPTOP:-}" ] || _out DP-/' "$T/bin/wlr-randr"
printf '%s\n' 'grid 3 3' 'surface comms "@builtin" cell 0 0' \
  'surface code "@builtin" cell 1 0' > "$T/desks/BL.conf"
_o=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
  WAYLAND_DISPLAY=wayland-test HWDP_MACHINE_PROVIDERS="$T/no-machine" \
  HWDP_PROVIDER_ROOT="$T/no-user" HWDP_DRM="$T/drm-laptop" \
  XDG_RUNTIME_DIR="$T/run" HWDP_SURFACES="$T/surf" HWDP_DESKS="$T/desks" \
  ONLY_LAPTOP=yes sh "$KA" surfaces 2>&1) || fail "generic BL failed: $_o"
[ "$_o" = "comms eDP-1 0 0 0 0 2880 1800
code eDP-1 1 0 0 0 2880 1800" ] \
  || fail "a laptop alone must find BL.conf, @builtin its panel: $_o"
pass "a desk with no file of its own finds the generic one for its kind"

# --write from a generic file: it writes THIS desk's file and keeps the grid,
# and the generic file is left exactly as it was.
printf '%s\n' 'grid 3 3' 'surface comms "@builtin" cell 0 0' \
  > "$T/desks/BL+EL+EP.conf"
_g=$(cksum < "$T/desks/BL+EL+EP.conf")
printf 'surface code DP-2 cell 1 0\n' | wr >/dev/null \
  || fail "--write from a generic desk failed"
grep -qx 'grid 3 3' "$FD" || fail "--write must keep the grid: $(cat "$FD")"
[ "$(cksum < "$T/desks/BL+EL+EP.conf")" = "$_g" ] \
  || fail "--write must never change the generic file"
pass "--write writes this desk's own file, keeping the generic one's grid"

# --- --write-names: the one writer of the global list -------------------------
# A name ANY desk file still places cannot be dropped (the list is global, so
# a desk the tool cannot see must not be broken by it); a doubled name is
# refused; a refusal leaves the list exactly as it was.
wn() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" HWDP_DESKS="$T/desks" \
    HWDP_SURFACES="$T/surf" sh "$KA" surfaces --write-names
}
rm -f "$F"    # the older per-id file above places names not listed here
printf '%s\n' 'comms Work Comms' 'code' 'elsewhere' 'spare' 'extra Extra' \
  | wn >/dev/null || fail "--write-names refused a valid list"
grep -qx 'extra Extra' "$NM" || fail "--write-names did not write: $(cat "$NM")"
_before=$(cksum < "$NM")
if printf '%s\n' 'code' 'elsewhere' 'spare' | wn >/dev/null 2>"$T/err"; then
  fail "--write-names dropped a name a desk places"
fi
grep -q '`comms` is placed by' "$T/err" \
  || fail "the refusal must name what places it: $(cat "$T/err")"
printf 'a\na\n' | wn >/dev/null 2>&1 && fail "--write-names took a doubled name"
[ "$(cksum < "$NM")" = "$_before" ] || fail "a refusal must leave the list"
pass "--write-names: refuses to drop a placed name or double one, else writes"

# The names list's first home (~/.config/hwdp/surfaces.names) is still read,
# and written, while the new one (in the desks dir) does not exist.
mv "$NM" "$T/home/.config/hwdp/surfaces.names" 2>/dev/null \
  || { mkdir -p "$T/home/.config/hwdp"
       mv "$NM" "$T/home/.config/hwdp/surfaces.names"; }
[ "$(run --names | sed -n 1p)" = "comms Work Comms" ] \
  || fail "the old names path must still be read: $(run --names)"
printf '%s\n' 'comms' 'code' 'elsewhere' 'spare' 'extra' 'later' | wn \
  >/dev/null || fail "writing at the old path failed"
[ ! -e "$NM" ] && grep -qx later "$T/home/.config/hwdp/surfaces.names" \
  || fail "the writer must write where it read, until the file is moved"
pass "the names list's first home is still read and written until moved"

# --- the `saved` edge: both writers announce what they wrote ------------------
# So an integrator can record the desk tool's data at once, not at the next
# layout save. NOT `mapped` (that means a layout profile exists). The hook is
# told the edge and the file.
mkdir -p "$T/home/.config/hwdp/hooks/saved.d"
cat > "$T/home/.config/hwdp/hooks/saved.d/10-rec" <<HOOK
#!/bin/sh
echo "\$HWDP_EDGE \$HWDP_SAVED" >> "$T/saved.log"
HOOK
chmod +x "$T/home/.config/hwdp/hooks/saved.d/10-rec"
: > "$T/saved.log"
printf 'surface code DP-2 cell 1 0\n' | wr >/dev/null || fail "--write failed"
grep -qx "saved $FD" "$T/saved.log" \
  || fail "--write must fire saved with the desk file: $(cat "$T/saved.log")"
printf '%s\n' comms code elsewhere spare extra later | wn >/dev/null \
  || fail "--write-names failed"
grep -q "^saved .*surfaces.names$" "$T/saved.log" \
  || fail "--write-names must fire saved: $(cat "$T/saved.log")"
if printf 'surface a DP-9 cell 0 0\n' | wr >/dev/null 2>&1; then
  fail "--write accepted an unknown output"
fi
[ "$(wc -l < "$T/saved.log")" -eq 2 ] \
  || fail "a refused write must fire nothing: $(cat "$T/saved.log")"
pass "both writers fire saved with the file, a refused write nothing"
