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
# Names past the old fixed width of 12 still line up: the column is as wide
# as the longest name.
printf 'surface a-long-surface-name "Dell WIDE SN3" cell 3 0\n' >> "$F"
_c=$(run --check) || fail "--check with a long name must exit 0"
printf '%s\n' "$_c" | awk '/^ok / { c = index($0, " " $3 " ")
    if (n++ && c != c0) bad = 1; c0 = c } END { exit bad || n < 5 }' \
  || fail "--check names do not line up: $_c"
sed -i '/a-long-surface-name/d' "$F"
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
  'expected `grid`, `surface`, `split`, `wallpaper` or `default`'
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
[ "$(run --names | sed -n 1p)" = "comms: Work Comms" ] \
  && [ "$(run --names | sed -n 2p)" = "code: code" ] \
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

# And WRITES over it, the whole desk by connector as the tool sends it: the
# built-in is "@builtin" in the generic file and its EDID name in the lines
# given, two spellings of ONE switched-on panel. Kept as a panel not switched
# on, every line came out twice and the save was refused "defined twice"
# (dragonfly, 2026-11-18, growing BL to 4x3).
_lw=$(printf '%s\n' 'grid 4 3' 'surface comms eDP-1 cell 0 0 full' \
  'surface code eDP-1 cell 1 0 full' 'surface spare eDP-1 cell 3 0 full' \
  | env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
  WAYLAND_DISPLAY=wayland-test HWDP_MACHINE_PROVIDERS="$T/no-machine" \
  HWDP_PROVIDER_ROOT="$T/no-user" HWDP_DRM="$T/drm-laptop" \
  XDG_RUNTIME_DIR="$T/run" HWDP_SURFACES="$T/surf" HWDP_DESKS="$T/desks" \
  ONLY_LAPTOP=yes sh "$KA" surfaces --write 2>&1) \
  || fail "a laptop alone could not write over the generic BL file: $_lw"
_lf=$(ls "$T/desks"/*.conf | grep -v -e '/BL.conf$' -e '/BL+EL+EP.conf$' \
  | head -1)
[ "$(grep -c '^surface ' "$_lf")" -eq 3 ] \
  || fail "a laptop's own file must hold each surface once: $(cat "$_lf")"
# By its ROLE, alone as at a desk: by EDID name, `hwdp desks` read a
# laptop's own desk as an external panel.
[ "$(grep -c '^surface .* "@builtin" ' "$_lf")" -eq 3 ] \
  || fail "a laptop alone must be written as \"@builtin\": $(cat "$_lf")"
rm -f "$_lf"
pass "a laptop alone writes over the generic file, each surface once"

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

# The mirror image, docked: the desk's own file names the laptop by its EDID
# name, the lines given say "@builtin" (its role at a desk). Still one panel.
# The desk file is restored after: later cases read what it held.
cp "$FD" "$T/fd.keep"
printf '%s\n' 'grid 3 3' 'surface ref "Acme LAPTOP SN1" cell 2 1 right' \
  > "$FD"
printf '%s\n' 'surface ref eDP-1 cell 2 1 right' \
  'surface code DP-2 cell 1 0' | wr >/dev/null 2>"$T/err" \
  || fail "docked, a file naming the laptop by EDID was refused: \
$(cat "$T/err")"
[ "$(grep -c '^surface ref ' "$FD")" -eq 1 ] \
  || fail "the laptop's surface must be written once: $(cat "$FD")"
cp "$T/fd.keep" "$FD"
pass "docked, a file naming the laptop by EDID name is replaced, not doubled"

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
[ "$(run --names | sed -n 1p)" = "comms: Work Comms" ] \
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
# And told its own name, as HWDP_HOOK.
printf '#!/bin/sh\necho "$HWDP_HOOK" >> "%s/hook.log"\n' "$T" \
  > "$T/home/.config/hwdp/hooks/saved.d/20-name"
chmod +x "$T/home/.config/hwdp/hooks/saved.d/20-name"
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
[ "$(sort -u "$T/hook.log")" = "saved.d/20-name" ] \
  || fail "a hook must be told its name as HWDP_HOOK: $(cat "$T/hook.log")"
pass "both writers fire saved with the file, a refused write nothing"

# --- splits: a panel CUT in one cell, kept even with nothing placed -----------
# Written by connector, filed by EDID name; read back resolved (--splits) and
# raw; a surface must use its split's halves; each cell decides for itself;
# a split on a panel not switched on survives a rewrite; and a half with no
# split line (a file from before splits) still resolves, its split implied.
printf '%s\n' 'split DP-1 cell 0 0 top-bottom' \
  'surface comms DP-1 cell 0 0 bottom' 'split DP-2 cell 1 0 left-right' \
  'surface code DP-1 cell 1 0' | wr >/dev/null 2>"$T/err" \
  || fail "--write refused splits: $(cat "$T/err")"
grep -qx 'split "Dell PORTRAIT SN2" cell 0 0 top-bottom' "$FD" \
  || fail "--write must file a split by EDID name: $(cat "$FD")"
[ "$(run --splits)" = "$(printf 'DP-1 0 0 top-bottom\nDP-2 1 0 left-right')" ] \
  || fail "--splits must resolve to connectors: '$(run --splits)'"
run --raw | grep -qx "$(printf 'split\t-\tDell WIDE SN3\t1\t0\tleft-right')" \
  || fail "--raw must carry the split: $(run --raw)"
[ "$(run 2>/dev/null | awk '$1 == "code"')" = \
  "code DP-1 1 0 0 0 2160 3840" ] \
  || fail "a panel split in one cell must be whole in the next: $(run)"
# An empty split (DP-2 in 1 0) is kept: nothing else records it.
_before=$(cksum < "$FD")
if printf '%s\n' 'split DP-1 cell 0 0 top-bottom' \
    'surface comms DP-1 cell 0 0' | wr >/dev/null 2>"$T/err"; then
  fail "--write took a WHOLE surface on a split panel"
fi
grep -q 'split top-bottom in cell 0 0' "$T/err" \
  || fail "the refusal must name the split: $(cat "$T/err")"
[ "$(cksum < "$FD")" = "$_before" ] || fail "a refusal must leave the file"
_twice=$(printf 'split DP-1 cell 0 0 %s\n' top-bottom left-right)
for _bad in 'split DP-1 cell 0 0 diagonal' "$_twice" \
    'split DP-1 cell 9 9 top-bottom' 'split DP-9 cell 0 0 top-bottom'; do
  printf '%s\n' "$_bad" | wr >/dev/null 2>&1 \
    && fail "--write took a bad split: $_bad"
done
[ "$(cksum < "$FD")" = "$_before" ] || fail "bad splits must leave the file"
printf 'split "Nope ELSEWHERE SN8" cell 1 1 left-right\n' >> "$FD"
printf 'surface code DP-2 cell 1 0\n' | wr >/dev/null \
  || fail "a rewrite failed"
grep -qx 'split "Nope ELSEWHERE SN8" cell 1 1 left-right' "$FD" \
  || fail "a split on a panel not switched on was lost: $(cat "$FD")"
printf 'surface comms DP-1 cell 0 0 top\nsurface code DP-1 cell 0 0 bottom\n' \
  | wr >/dev/null || fail "halves with no split line must still be accepted"
[ -z "$(run --splits)" ] || fail "an implied split is not a written one"
pass "splits: written, resolved, raw, enforced, per cell, kept when unseen"

# --- wallpapers: one per workspace, per desk, by their own writer ------------
# `X Y FILE` in, `wallpaper cell X Y FILE` in the desk file, `X Y FILE` out
# (the shape a wallpaper map already has), cells inside the grid only. The
# surfaces writer keeps them; this one keeps everything else.
ww() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY=wayland-test HWDP_MACHINE_PROVIDERS="$T/no-machine" \
    HWDP_PROVIDER_ROOT="$T/no-user" HWDP_DRM="$T/drm" \
    XDG_RUNTIME_DIR="$T/run" HWDP_SURFACES="$T/surf" HWDP_DESKS="$T/desks" \
    ${DESK:+HWDP_DESK="$DESK"} LAPTOP_ON=yes \
    sh "$KA" surfaces --write-wallpapers
}
printf 'grid 3 2\nsurface code DP-1 cell 1 0\n' | wr >/dev/null \
  || fail "a desk to put wallpapers on was refused"
_surf_before=$(grep '^surface ' "$FD")
: > "$T/saved.log"
printf '%s\n' '0 0 bubbles.jpg' '1 0 night sky.png' '2 1 sub/fog.jpg' \
  | ww >/dev/null 2>"$T/err" \
  || fail "--write-wallpapers failed: $(cat "$T/err")"
[ "$(run --wallpapers)" = "$(printf '0 0 bubbles.jpg\n1 0 night sky.png
2 1 sub/fog.jpg')" ] || fail "--wallpapers: '$(run --wallpapers)'"
[ "$(grep '^surface ' "$FD")" = "$_surf_before" ] \
  || fail "--write-wallpapers changed the surfaces: $(cat "$FD")"
grep -qx "saved $FD" "$T/saved.log" \
  || fail "--write-wallpapers must fire saved: $(cat "$T/saved.log")"
printf 'surface code DP-2 cell 1 0\n' | wr >/dev/null || fail "a rewrite failed"
[ "$(run --wallpapers | wc -l)" -eq 3 ] \
  || fail "--write dropped the wallpapers: $(cat "$FD")"
_before=$(cksum < "$FD")
for _bad in '0 0 /etc/passwd' '0 0 ../up.jpg' '0 x a.jpg' '1 1'; do
  printf '%s\n' '0 1 fine.jpg' "$_bad" | ww >/dev/null 2>&1 \
    && fail "--write-wallpapers took a bad line: $_bad"
done
printf '0 0 a.jpg\n0 0 b.jpg\n' | ww >/dev/null 2>"$T/err" \
  && fail "--write-wallpapers took one cell twice"
grep -q 'cell 0 0 is set twice' "$T/err" || fail "say the cell: $(cat "$T/err")"
[ "$(cksum < "$FD")" = "$_before" ] || fail "a refusal must leave the file"
# Outside the grid: kept (a shrink must not break the file), not published,
# and --check says so.
printf '0 0 a.jpg\n5 5 far.jpg\n' | ww >/dev/null \
  || fail "a wallpaper outside the grid was refused"
[ "$(run --wallpapers)" = "0 0 a.jpg" ] \
  || fail "a wallpaper outside the grid was published: $(run --wallpapers)"
run --check 2>&1 | grep -q 'wallpaper for cell 5 5 is outside the grid' \
  || fail "--check must note it: $(run --check 2>&1)"
: | ww >/dev/null || fail "clearing the wallpapers failed"
[ -z "$(run --wallpapers)" ] || fail "nothing given must clear them"
grep -q '^wallpaper' "$FD" && fail "cleared wallpapers left lines: $(cat "$FD")"
# Away from the desk: the same writer, by HWDP_DESK.
_k=$(basename "$FD" .conf)
printf '1 1 away.jpg\n' | DESK=$_k ww >/dev/null 2>"$T/err" \
  || fail "--write-wallpapers away from the desk: $(cat "$T/err")"
grep -qx 'wallpaper cell 1 1 away.jpg' "$FD" \
  || fail "the named desk did not get it: $(cat "$FD")"
pass "wallpapers: written, published in the grid, kept, refused whole, cleared"

# --- the integrator's DEFAULT wallpapers: a provider, handed the shape --------
ww_any() {   # surfaces with any arguments, as ww runs it (DESK, the env)
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY=wayland-test HWDP_MACHINE_PROVIDERS="$T/no-machine" \
    HWDP_PROVIDER_ROOT="$T/no-user" HWDP_DRM="$T/drm" \
    XDG_RUNTIME_DIR="$T/run" HWDP_SURFACES="$T/surf" HWDP_DESKS="$T/desks" \
    ${DESK:+HWDP_DESK="$DESK"} LAPTOP_ON=yes sh "$KA" surfaces "$@"
}
# hwdp knows no image of its own. A `wallpapers` provider is handed this
# desk's SHAPE (the attached one's, or a desk's away from it from its files)
# and its `X Y FILE` lines are published, anything else dropped.
mkdir -p "$T/no-user/wallpapers"
cat > "$T/no-user/wallpapers/50-shape" <<EOF
#!/bin/sh
echo "\$1" >> "$T/asked"
printf '0 0 %s-a.jpg\n1 0 night sky.jpg\nnot a line\n' "\$1"
EOF
chmod +x "$T/no-user/wallpapers/50-shape"
: > "$T/asked"
_dw=$(run --default-wallpapers) || fail "--default-wallpapers failed"
[ -n "$(cat "$T/asked")" ] || fail "the provider was never asked"
[ "$(printf '%s\n' "$_dw" | head -1)" = "0 0 $(head -1 "$T/asked")-a.jpg" ] \
  || fail "the provider was not handed the shape: $_dw / $(cat "$T/asked")"
printf '%s\n' "$_dw" | grep -qx '1 0 night sky.jpg' \
  || fail "a name with a space must stay whole: $_dw"
printf '%s\n' "$_dw" | grep -q 'not a line' && fail "a bad line published"
: > "$T/asked"
_dw=$(DESK=BL ww_any --default-wallpapers) \
  || fail "--default-wallpapers away from the desk failed"
[ "$(cat "$T/asked")" = BL ] \
  || fail "away from the desk the shape must be its own: $(cat "$T/asked")"
rm -f "$T/no-user/wallpapers/50-shape"
[ -z "$(run --default-wallpapers)" ] || fail "no provider must be silence"
pass "default wallpapers: asked of a provider with the desk's shape"

# --- --follow: where a person on a cell of one desk should be on this one ----
# Surface names are global, so the join is by name: the old cell's surfaces
# (the built-in's first, whole before halves) then the names an integrator
# remembers, the first placed HERE winning.
rm -rf "$T/desks"; mkdir -p "$T/desks"
printf '%s\n' comms code mail spare > "$T/desks/surfaces.names"
cat > "$FD" <<'DESK'
grid 2 2
surface comms "Dell PORTRAIT SN2" cell 1 1 bottom
surface code  "Dell WIDE SN3"     cell 0 1
surface mail  "@builtin"          cell 1 0
DESK
cat > "$T/desks/0fa1afa1afa1.conf" <<'DESK'
grid 3 3
surface mail  "@builtin" cell 2 0
surface code  "@builtin" cell 0 2 bottom
surface comms "@builtin" cell 0 2 top
surface spare "@builtin" cell 1 1
surface code2 "Dell WIDE SN3" cell 2 1
DESK
printf '%s\n' 'surface code "Dell WIDE SN3" cell 2 1' \
  'surface mail "@builtin" cell 2 1 bottom' > "$T/desks/0fa1afa1afa2.conf"
_f() { run --follow "$@" 2>&1; }
[ "$(_f 0fa1afa1afa1 2 0)" = "1 0 mail" ] \
  || fail "a cell follows to where its surface is now: $(_f 0fa1afa1afa1 2 0)"
[ "$(_f 0fa1afa1afa1 0 2)" = "1 1 comms" ] \
  || fail "of two halves the top comes first: $(_f 0fa1afa1afa1 0 2)"
[ "$(_f 0fa1afa1afa2 2 1)" = "1 0 mail" ] \
  || fail "the built-in's surface comes first: $(_f 0fa1afa1afa2 2 1)"
_rc=0; _o=$(run --follow 0fa1afa1afa1 1 1) || _rc=$?
[ "$_rc" = 1 ] && [ "$_o" = "- - spare" ] \
  || fail "names not placed here: exit 1, saying what to remember: $_rc '$_o'"
_rc=0; _o=$(run --follow 0fa1afa1afa1 9 9) || _rc=$?
[ "$_rc" = 1 ] && [ -z "$_o" ] \
  || fail "nothing to look for: exit 1 and nothing, got $_rc '$_o'"
[ "$(_f 0fa1afa1afa1 1 1 code)" = "0 1 code" ] \
  || fail "a remembered name carries it: $(_f 0fa1afa1afa1 1 1 code)"
[ "$(_f '' 0 0 mail)" = "1 0 mail" ] \
  || fail "with no desk before, the names alone: $(_f '' 0 0 mail)"
printf 'surface code "@builtin" cell 2 2\n' > "$T/desks/BL.conf"
[ "$(_f BL 2 2)" = "0 1 code" ] \
  || fail "a generic desk's file is read too: $(_f BL 2 2)"
# A desk with no file of its own falls back to its KIND's (its profile says
# it is a laptop alone, BL), as the attached desk does.
mkdir -p "$T/home/.config/kanshi/profiles"
printf '%s\n' 'profile x {' \
  '  output "@builtin" mode 2880x1800 position 0,0 transform normal' '}' \
  > "$T/home/.config/kanshi/profiles/0fa1afa1afa3.conf"
[ "$(_f 0fa1afa1afa3 2 2)" = "0 1 code" ] \
  || fail "a desk with no file follows by its kind's: $(_f 0fa1afa1afa3 2 2)"
run --follow 0fa1afa1afa1 2 >/dev/null 2>&1 && fail "--follow took 2 args"
run --follow 0fa1afa1afa1 a 0 >/dev/null 2>&1 && fail "a non-cell was taken"
run --follow ../x 0 0 >/dev/null 2>&1 && fail "a path was taken as a desk"
pass "--follow: a cell's surfaces, or remembered names, found on this desk"

# --- --labels: the plain record, then each surface's label, opt-in -----------
rm -rf "$T/desks"; mkdir -p "$T/desks"
printf '%s\n' 'comms Work Comms' 'code' > "$T/desks/surfaces.names"
printf '%s\n' 'surface comms "Dell PORTRAIT SN2" cell 0 0 bottom' \
  'surface code "Dell WIDE SN3" cell 1 0' > "$FD"
_p=$(run) || fail "the plain record failed"
_l=$(run --labels) || fail "--labels failed"
[ "$(printf '%s\n' "$_p" | awk 'NF != 8' | wc -l)" -eq 0 ] \
  || fail "the default record must stay eight fields: $_p"
[ "$(printf '%s\n' "$_l" | grep '^comms ' | cut -d' ' -f1-8)" = \
  "$(printf '%s\n' "$_p" | grep '^comms ')" ] \
  || fail "--labels must lead with the same eight fields: $_l"
printf '%s\n' "$_l" | grep -q '^comms .* 1920 Work Comms$' \
  || fail "the label, spaces and all, ends the line: $_l"
printf '%s\n' "$_l" | grep -q '^code .* code$' \
  || fail "a name with no label is labelled by itself: $_l"
mv "$T/desks/surfaces.names" "$T/names.keep"
# The OLD names path too, or the command falls back to it and this is not
# the no-list case at all (it was not, until a planted bug passed it).
[ -f "$T/home/.config/hwdp/surfaces.names" ] \
  && mv "$T/home/.config/hwdp/surfaces.names" "$T/old-names.keep"
_l=$(run --labels) || fail "--labels with no names list failed"
[ "$(printf '%s\n' "$_l" | wc -l)" -eq 2 ] \
  && printf '%s\n' "$_l" | grep -q '^comms .* comms$' \
  || fail "with no names list every line is still there, by handle: $_l"
mv "$T/names.keep" "$T/desks/surfaces.names"
[ -f "$T/old-names.keep" ] \
  && mv "$T/old-names.keep" "$T/home/.config/hwdp/surfaces.names"
printf 'eng-ops Engineering: Operations\n' >> "$T/desks/surfaces.names"
[ "$(run --names | grep '^eng-ops')" = "eng-ops: Engineering: Operations" ] \
  || fail "--names: the first colon divides, a label keeps its own: $(run \
--names)"
printf 'surface comms "Dell WIDE SN3" cell 1 0\n' >> "$FD"
_rc=0; _l=$(run --labels 2>/dev/null) || _rc=$?
[ "$_rc" = 2 ] && [ -z "$_l" ] \
  || fail "a broken file: exit 2 and nothing, got $_rc '$_l'"
pass "--labels: the eight fields, then the label; opt-in, the record intact"
