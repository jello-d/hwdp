#!/bin/sh
# desks.t - every desk by NAME, and a desk edited AWAY from its panels.
#
# `hwdp desks` lists the desks the files describe, each with a name made
# from its hardware or chosen with --name; `hwdp arrange <name>` opens the
# tool on one; and the two writers it saves through work with no panel of
# that desk attached: `hwdp surfaces` under HWDP_DESK, `hwdp profile --write`.
# Headless throughout: an empty DRM tree and no compositor, which is exactly
# the state of a laptop away from the desk being edited.
. "$(dirname "$0")/harness_lib"
harness_init desks

KA=$HERE/bin/hwdp
P=$T/config/kanshi/profiles; D=$T/config/hwdp/desks
mkdir -p "$P" "$D" "$T/drm" "$T/hooks"
run() {
  env -i PATH="/usr/bin:/bin" HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
    XDG_STATE_HOME="$T/state" XDG_RUNTIME_DIR="$T/run" HWDP_DRM="$T/drm" \
    HWDP_MACHINE_PROVIDERS="$T/no-machine" HWDP_PROVIDER_ROOT="$T/no-user" \
    HWDP_HOOK_ROOT="$T/hooks" HWDP_MACHINE_HOOKS="$T/no-hooks" \
    ${DESK:+HWDP_DESK="$DESK"} sh "$KA" "$@"
}

# A docked desk (the laptop's panel by role), written the way arrange writes
# it; a wall of three identical panels from before the hwdp-rect comments
# (sizes only from the mode, rotated); a second desk of the SAME two models
# (different serials), whose made name must not repeat the first; and the
# generic laptop desk, a desk file with no profile.
printf 'on\t@builtin\t0\t0\t0\tnormal\t0\t1740\t2880\t1800
on\tDell Inc. DELL U2715H SER1\t2560\t1440\t59.951\tnormal\t320\t300\t2560\t1440
on\tDell Inc. DELL P2721Q SER2\t3840\t2160\t59.997\t270\t2880\t0\t2160\t3840
' | DESK= run profile --write aaaaaaaaaaaa >/dev/null \
  || fail "profile --write failed with no panels attached"
[ -f "$P/aaaaaaaaaaaa.conf" ] || fail "profile --write wrote nothing"
grep -q '^    output "Dell Inc. DELL P2721Q SER2" mode 3840x2160@59.997Hz' \
  "$P/aaaaaaaaaaaa.conf" || fail "the written profile lost a mode"
grep -q '^# hwdp-rect "@builtin" 0 1740 2880 1800$' "$P/aaaaaaaaaaaa.conf" \
  || fail "the written profile lost the rects that re-place it"
: | run profile --write bbbbbbbbbbbb 2>/dev/null \
  && fail "profile --write took no records" || :
[ -e "$P/bbbbbbbbbbbb.conf" ] && fail "an empty profile was written" || :
cat > "$P/cccccccccccc.conf" <<'EOF'
profile hwdp-cccccccccccc {
    output "Dell Inc. AW2725Q SA" mode 3840x2160 transform 90 position 2160,0
    output "Dell Inc. AW2725Q SB" mode 3840x2160 transform 90 position 0,0
    output "Dell Inc. AW2725Q SC" mode 3840x2160 transform 270 position 4320,0
}
EOF
sed 's/SER1/SER3/; s/SER2/SER4/; s/aaaaaaaaaaaa/dddddddddddd/' \
  "$P/aaaaaaaaaaaa.conf" > "$P/dddddddddddd.conf"
printf 'calendar Calendar\nmail Mail\nchat Chat\n' > "$D/surfaces.names"
printf 'grid 3 3\nsurface calendar "@builtin" cell 0 0\n' > "$D/BL.conf"
cat > "$D/aaaaaaaaaaaa.conf" <<'EOF'
grid 2 2
surface calendar "Dell Inc. DELL P2721Q SER2" cell 0 0 top
surface mail "Dell Inc. DELL P2721Q SER2" cell 0 0 bottom
default chat "@builtin"
EOF

# --- the list -------------------------------------------------------------
_o=$(DESK= run desks) || fail "hwdp desks failed: $_o"
# A row and its wrapped PANELS lines (which open with 4+ spaces), as one.
row() { printf '%s\n' "$_o" | awk -v k="$1" '
  f && /^    / { sub(/^ +/, ""); r = r " " $0; next }
  f { exit }
  $0 ~ " " k " " { r = $0; f = 1 }
  END { print r }'; }
case $(row BL) in
  *" laptop "*"BL"*"3x3"*"1 "*) ;;
  *) fail "the generic laptop desk: $(row BL)" ;;
esac
case $(row aaaaaaaaaaaa) in
  *" u2715h+p2721q "*"BL+EL+EP"*"2x2"*"2+default"*"laptop, U2715H, P2721Q"*)
    ;;
  *) fail "a docked desk is named by its models, left to right: \
$(row aaaaaaaaaaaa)" ;;
esac
case $(row cccccccccccc) in
  *" aw2725q-x3 "*"EP+EP+EP"*"AW2725Q x3") ;;
  *) fail "a wall from mode-only lines (rotated, so portrait): \
$(row cccccccccccc)" ;;
esac
case $(row dddddddddddd) in
  *" u2715h+p2721q-2 "*) ;;
  *) fail "the same models at a second desk must get -2: $(row dddddddddddd)" ;;
esac
pass "desks are listed with names made from their hardware"

# --- the list fits 80 columns, wrapping PANELS in its own column -----------
# AT MOST 79: a line filling the last column of an 80-column terminal wraps
# its final character on some (seen live with the made names, a row of
# exactly 80).
# A long name widens NAME; PANELS then wraps between words, its continuation
# under the column, and once too narrow (under 16) moves below the row.
fits() { printf '%s\n' "$1" | awk 'length > 79 { print "over 79: " $0; b = 1 }
  END { exit b }'; }
# Here the -2 name alone leaves PANELS 20 columns, so one row wraps.
_o=$(DESK= run desks)
fits "$_o" || fail "the list ran past 79 columns: $_o"
_c=$(printf '%s\n' "$_o" | awk 'NR == 1 { print index($0, "PANELS") }')
printf '%s\n' "$_o" | awk -v c="$_c" '
  / aaaaaaaaaaaa / { getline; n = match($0, /[^ ]/)
    exit !(n == c && $0 ~ /P2721Q$/) }' \
  || fail "a wrapped PANELS line is not under its column: $_o"
DESK= run desks --name u2715h+p2721q \
  a-name-of-twenty-five-chr 2>/dev/null \
  && fail "a name over 24 characters was taken" || :
DESK= run desks --name u2715h+p2721q twenty-four-characters-x >/dev/null \
  || fail "a 24-character name was refused"
_o=$(DESK= run desks)
fits "$_o" || fail "the list ran past 79 columns: $_o"
printf '%s\n' "$_o" | awk '/ twenty-four-characters-x / { getline
  exit !($0 ~ /^    laptop, U2715H, P2721Q$/) }' \
  || fail "with no room beside, PANELS goes on its own line: $_o"
case $(printf '%s\n' "$_o" | head -1) in
  *PANELS*) fail "the header names a column that is not beside it" ;;
esac
printf '%s\n' "$_o" | grep -q ' $' && fail "a line ends in spaces: $_o"
DESK= run desks --name twenty-four-characters-x - >/dev/null
# A MADE name has no cap (four different monitors make a long one), so the
# list must hold one too: it takes a line of its own.
_long=a-name-so-long-there-is-no-room-for-panels-beside-it
printf 'aaaaaaaaaaaa %s\n' "$_long" >> "$D/desk-names"
_o=$(DESK= run desks)
fits "$_o" || fail "the list ran past 79 columns: $_o"
printf '%s\n' "$_o" | awk '/a-name-so-long/ { getline
  exit !($0 ~ /^ {28}aaaaaaaaaaaa /) }' \
  || fail "a name past the column is not on a line of its own: $_o"
DESK= run desks --name "$_long" - >/dev/null
# THE BOUNDARY, both ways: chosen names one character apart walk the PANELS
# column across it, so some width puts that row at exactly 79 unwrapped (it
# must NOT wrap) and the next at 80 (it MUST). A row is wrapped when the
# line after it is a continuation (four spaces or more; a row opens with
# two, or the `*` mark and one).
_seen=
# The NAME column is as wide as the WIDEST name, so the other long one
# (u2715h+p2721q-2, 15) is shortened for the sweep, or it holds the column.
DESK= run desks --name u2715h+p2721q-2 dd >/dev/null || fail "--name dd"
for _w in 6 7 8 9 10 11 12 13 14 15 16 17 18; do
  _nm=$(printf 'w%0*d' $((_w - 1)) 0)
  DESK= run desks --name u2715h+p2721q "$_nm" >/dev/null || fail "--name $_nm"
  _o=$(DESK= run desks)
  fits "$_o" || fail "the list ran past 79 columns at a $_w-wide name: $_o"
  _c=$(printf '%s\n' "$_o" | awk 'NR == 1 { print index($0, "PANELS") }')
  [ "$_c" -gt 0 ] || continue                    # PANELS went below the row
  _full=$((_c - 1 + 22))                          # laptop, U2715H, P2721Q
  _wr=$(printf '%s\n' "$_o" | awk -v n="$_nm" '$0 ~ " " n " " { getline
    print (/^    / ? 1 : 0); exit }')
  if [ "$_full" -le 79 ]; then
    [ "$_wr" = 0 ] || fail "a $_full-wide row wrapped although it fits: $_o"
  else
    [ "$_wr" = 1 ] || fail "a $_full-wide row did not wrap: $_o"
  fi
  _seen="$_seen $_full"
  DESK= run desks --name "$_nm" - >/dev/null
done
DESK= run desks --name dd - >/dev/null
case "$_seen " in *" 79 "*) ;; *) fail "no row of 79 (rows:$_seen)" ;; esac
case "$_seen " in *" 80 "*) ;; *) fail "no row of 80 (rows:$_seen)" ;; esac
pass "the list fits 80 columns, wrapping panels under their column"

# --- names: chosen, refused, resolved, reverted ----------------------------
DESK= run desks --name u2715h+p2721q office >/dev/null \
  || fail "naming a desk failed"
[ "$(DESK= run desks --resolve office)" = aaaaaaaaaaaa ] \
  || fail "a chosen name does not resolve"
[ "$(DESK= run desks --resolve aaaaaaaaaaaa)" = aaaaaaaaaaaa ] \
  || fail "a key does not resolve to itself"
[ "$(DESK= run desks --resolve u2715h+p2721q)" = dddddddddddd ] \
  || fail "once the first desk is renamed, its made name is the other's"
DESK= run desks --name office Office 2>/dev/null \
  && fail "a name with capitals (a connector could look so) was taken" || :
DESK= run desks --name laptop office 2>/dev/null \
  && fail "a name already in use was taken twice" || :
DESK= run desks --resolve nowhere 2>/dev/null \
  && fail "an unknown name resolved" || :
DESK= run desks --name office - >/dev/null || fail "reverting a name failed"
[ "$(DESK= run desks --resolve u2715h+p2721q)" = aaaaaaaaaaaa ] \
  || fail "a reverted desk does not get its made name back"
pass "names: chosen, refused (capitals, taken), resolved, reverted"

# --- surfaces on a desk that is not attached --------------------------------
DESK=aaaaaaaaaaaa
[ "$(run surfaces --grid)" = "2 2" ] || fail "--grid away from the desk"
_r=$(run surfaces --raw) || fail "--raw away from the desk"
printf '%s\n' "$_r" | grep -q "^default	chat	@builtin	\*	\*	full$" \
  || fail "--raw lost the default: $_r"
printf '%s\n' "$_r" | grep -q \
  "^surface	mail	Dell Inc. DELL P2721Q SER2	0	0	bottom$" \
  || fail "--raw lost a surface: $_r"
printf '%s\n' 'grid 2 2' \
  'surface calendar "Dell Inc. DELL P2721Q SER2" cell 1 0 top' \
  'surface mail "Dell Inc. DELL P2721Q SER2" cell 0 0 bottom' \
  'default chat "@builtin"' | run surfaces --write >/dev/null \
  || fail "--write away from the desk"
grep -q '^surface calendar "Dell Inc. DELL P2721Q SER2" cell 1 0 top$' \
  "$D/aaaaaaaaaaaa.conf" || fail "the write did not land"
[ "$(grep -c '^surface calendar' "$D/aaaaaaaaaaaa.conf")" = 1 ] \
  || fail "the old line was KEPT beside the new: away from a desk, the" \
       "writer holds the whole desk and must replace it"
cp "$D/aaaaaaaaaaaa.conf" "$T/keep"
printf '%s\n' 'surface calendar "Dell Inc. DELL P2721Q SER2" cell 0 0' \
  'surface mail "Dell Inc. DELL P2721Q SER2" cell 0 0 bottom' \
  | run surfaces --write 2>/dev/null && fail "a clash was written" || :
cmp -s "$T/keep" "$D/aaaaaaaaaaaa.conf" || fail "a refused write changed it"
printf 'surface calendar DP-7 cell 0 0\n' | run surfaces --write 2>"$T/err" \
  && fail "a connector was taken away from the desk" || :
grep -q 'name panels by quoted EDID name' "$T/err" \
  || fail "the connector refusal does not say what to do: $(cat "$T/err")"
run surfaces --check >/dev/null || fail "--check away from the desk"
DESK=
pass "surfaces read, written whole and validated with the desk away"

# --- hwdp arrange <name> ----------------------------------------------------
run arrange nowhere </dev/null 2>"$T/err" && fail "an unknown desk opened" || :
grep -q 'no desk named `nowhere`' "$T/err" || fail "unknown: $(cat "$T/err")"
run arrange u2715h+p2721q </dev/null 2>"$T/err" \
  && fail "the tool ran with no terminal" || :
grep -q 'needs a terminal' "$T/err" \
  || fail "a known desk did not reach the tool: $(cat "$T/err")"
pass "hwdp arrange <name> opens that desk; an unknown one is refused"

# --- the tool on a desk away from it ----------------------------------------
# The real arrange-tui, its offline adapter driven directly: it loads the desk
# from its files (labels, not EDID names), saves a rotation through
# `hwdp profile --write` and a moved surface through `hwdp surfaces` under
# HWDP_DESK, and refuses what needs the panels (preview, labels on glass).
_out=$(env -i PATH="/usr/bin:/bin" HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
  XDG_STATE_HOME="$T/state" XDG_RUNTIME_DIR="$T/run" HWDP_DRM="$T/drm" \
  HWDP_MACHINE_PROVIDERS="$T/no-machine" HWDP_PROVIDER_ROOT="$T/no-user" \
  HWDP_HOOK_ROOT="$T/hooks" HWDP_MACHINE_HOOKS="$T/no-hooks" \
  python3 -I - "$HERE" "$P" "$D" 2>&1 <<'PY'
import importlib.machinery, importlib.util, sys
here, P, D = sys.argv[1:4]
ld = importlib.machinery.SourceFileLoader("tui", here + "/libexec/arrange-tui")
sp = importlib.util.spec_from_loader("tui", ld)
tui = importlib.util.module_from_spec(sp)
ld.exec_module(tui)
fails = []
def check(label, cond, detail=""):
    if not cond:
        fails.append("%s %s" % (label, detail))
# parse_profile: a rect wins; without one the mode, turned by a quarter turn.
got = tui.parse_profile(open(P + "/cccccccccccc.conf").read(), None)
check("a mode-only rotated panel is portrait",
      [(g[4], g[5]) for g in got] == [(2160, 3840)] * 3, got)
hw = tui.OfflineHwdp("aaaaaaaaaaaa", "office")
outs = hw.geometry()
check("the desk loads from its profile, by label",
      [(o.label, o.x, o.y, o.w, o.h) for o in outs] ==
      [("laptop", 0, 1740, 2880, 1800), ("U2715H", 320, 300, 2560, 1440),
       ("P2721Q", 2880, 0, 2160, 3840)], [(o.label, o.rect()) for o in outs])
app = tui.App(tui.Desk(outs, hw.repack), hw)
hw.desk = app.desk
check("its surfaces load, by EDID name and role",
      sorted(x.key() for x in app.surfaces) ==
      sorted([("calendar", "Dell Inc. DELL P2721Q SER2", "top", 1, 0),
              ("mail", "Dell Inc. DELL P2721Q SER2", "bottom", 0, 0)])
      and app.default and app.default.conn == "@builtin",
      [x.key() for x in app.surfaces])
app._preview(0)
check("preview says the desk is not attached", "not attached" in app.msg,
      app.msg)
app._identify(0)
check("labels on glass say so too", "not attached" in app.msg
      and not app.ident, app.msg)
p27 = outs[2]
app.desk.rotate(p27)
rc, why = hw.arrange(None, app.desk.placements())
txt = open(P + "/aaaaaaaaaaaa.conf").read()
check("a rotation saves to the profile", rc == 0 and
      'output "Dell Inc. DELL P2721Q SER2" mode 3840x2160@59.997Hz' \
      ' transform normal' in txt and "# hwdp-rect" in txt, (rc, why, txt))
check("...with the laptop still by role and no mode",
      'output "@builtin" transform normal position' in txt, txt)
sv = [tui.Surface("calendar", "Dell Inc. DELL U2715H SER1", "full", 1, 1)]
rc, why = hw.write_desk((2, 2), sv, app.default)
dtxt = open(D + "/aaaaaaaaaaaa.conf").read()
check("a moved surface saves to the desk file", rc == 0 and
      'surface calendar "Dell Inc. DELL U2715H SER1" cell 1 1 full' in dtxt
      and "mail" not in dtxt, (rc, why, dtxt))
check("away from the desk, halves on file imply their split",
      app.splits.get(("Dell Inc. DELL P2721Q SER2", 0, 0)) == "top-bottom",
      app.splits)
cut = [("Dell Inc. DELL U2715H SER1", 0, 0, "left-right")]
rc, why = hw.write_desk((2, 2), sv, app.default, cut)
dtxt = open(D + "/aaaaaaaaaaaa.conf").read()
check("an empty split saves away from the desk, by quoted panel name",
      rc == 0 and 'split "Dell Inc. DELL U2715H SER1" cell 0 0 left-right'
      in dtxt, (rc, why, dtxt))
again = tui.OfflineHwdp("aaaaaaaaaaaa", "office")
app2 = tui.App(tui.Desk(again.geometry(), again.repack), again)
check("...and loads again as a split, never as a surface",
      app2.splits == {("Dell Inc. DELL U2715H SER1", 0, 0): "left-right"}
      and [x.key() for x in app2.surfaces] ==
      [("calendar", "Dell Inc. DELL U2715H SER1", "full", 1, 1)],
      (app2.splits, [x.key() for x in app2.surfaces]))
generic = tui.OfflineHwdp("BL", "laptop")
generic.geometry()
rc, why = generic.arrange(None, [])
check("a desk with no layout on record will not invent one",
      rc != 0 and "no layout recorded" in why, (rc, why))
print("\n".join(fails) if fails else "ALL-OK")
PY
)
[ "$_out" = ALL-OK ] || fail "$_out"
pass "the tool loads a desk away from it, and saves it there"
