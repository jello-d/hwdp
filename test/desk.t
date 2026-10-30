#!/bin/sh
# desk.t - a desk recorded from one laptop works for ANOTHER at the same desk.
#
# The user's plan, 2026-10-30: manifold is at the new desk on day one, a new
# laptop (dragonfly) replaces it days later, and the layout recorded from
# manifold should "just work" for dragonfly. It did not: the id that names a
# desk hashed every panel, the laptop's OWN panel included, so dragonfly at
# the same monitors was a different desk with no profile and no surfaces, and
# the profile named manifold's panel, which kanshi could never match.
#
# Now a built-in panel beside externals counts as a ROLE: `hwdp id --desk`
# is the same for both laptops, the profile and surfaces are filed by it, the
# built-in is written as "@builtin" with no mode, and layout fills in the
# live laptop's name and native mode, re-placing the desk for its size.
. "$(dirname "$0")/harness_lib"
harness_init desk

KA=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/drm" "$T/profiles" "$T/surf"

# Two laptops (LAPTOP=A|B, different panels and sizes) at one desk: a 4K
# portrait (DP-1) and a 4K landscape (DP-2). DOCK=no takes the externals away.
cat > "$T/bin/wlr-randr" <<'STUB'
#!/bin/sh
_out() {   # <conn> <make> <model> <serial> <w> <h> <x> <y> <tr> <enabled>
  cat <<BLK
$1 "$2 $3 $4 ($1)"
  Make: $2
  Model: $3
  Serial: $4
  Physical size: 600x340 mm
  Enabled: ${10}
  Modes:
    ${5}x${6} px, 60.000000 Hz (preferred, current)
  Position: $7,$8
  Transform: $9
  Scale: 1.000000
BLK
}
case ${LAPTOP:-A} in
  A) _out eDP-1 Lenovo X1 SNA 2880 1800 2640 3840 normal "${LID:-yes}" ;;
  B) _out eDP-1 Dell Latitude SNB 1920 1200 0 0 normal "${LID:-yes}" ;;
esac
if [ "${DOCK:-yes}" = yes ]; then
  _out DP-1 Acme PORTRAIT SN2 3840 2160 0 0 90 yes
  _out DP-2 Acme WIDE SN3 3840 2160 2160 1680 normal yes
fi
STUB
chmod +x "$T/bin/wlr-randr"

drm() {   # LAPTOP DOCK: the kernel's view, matching the stub
  rm -rf "$T/drm"; mkdir -p "$T/drm/card1-eDP-1"
  printf connected > "$T/drm/card1-eDP-1/status"
  printf 'EDID-LAPTOP-%s' "$1" > "$T/drm/card1-eDP-1/edid"
  [ "$2" = yes ] || return 0
  for _c in DP-1 DP-2; do
    mkdir -p "$T/drm/card1-$_c"
    printf connected > "$T/drm/card1-$_c/status"
    printf 'EDID-%s' "$_c" > "$T/drm/card1-$_c/edid"
  done
}
run() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY=wayland-test XDG_RUNTIME_DIR="$T/run" \
    HWDP_MACHINE_PROVIDERS="$T/no-machine" HWDP_PROVIDER_ROOT="$T/no-user" \
    HWDP_DRM="$T/drm" KANSHI_PROFILES="$T/profiles" \
    KANSHI_STICKY="$T/sticky" KANSHI_OUT="$T/out" HWDP_SURFACES="$T/surf" \
    LAPTOP="${LAPTOP:-A}" DOCK="${DOCK:-yes}" LID="${LID:-yes}" \
    sh "$KA" "$@"
}

# --- the ids ------------------------------------------------------------------
drm A yes; ida=$(run id); desk_a=$(run id --desk)
drm B yes; idb=$(LAPTOP=B run id); desk_b=$(LAPTOP=B run id --desk)
[ "$ida" != "$idb" ] || fail "two laptops' panels must still differ by id"
[ "$desk_a" = "$desk_b" ] || fail "the same desk must have ONE desk id"
[ "$desk_a" != "$ida" ] || fail "a docked laptop's desk id is its own"
drm A no
[ "$(run id --desk)" = "$(run id)" ] \
  || fail "a laptop ALONE keeps its exact id (the greeter needs the panel)"
rm -rf "$T/drm/card1-eDP-1"; drm A yes; rm -rf "$T/drm/card1-eDP-1"
[ "$(run id --desk)" = "$(run id)" ] \
  || fail "externals alone (no built-in) keep their exact id"
pass "one desk id for two laptops; nothing else changes id"

# --- laptop A lays the desk out -----------------------------------------------
drm A yes
P=$T/profiles/$desk_a.conf
_o=$(run arrange DP-1 'DP-2 right-of DP-1 align bottom' \
  'eDP-1 below DP-2 align center' 2>&1) || fail "arrange on A failed: $_o"
[ -f "$P" ] || fail "the profile must be filed under the desk id"
grep -q '^    output "@builtin" position 2640,3840$' "$P" \
  || fail "the built-in must be the ROLE with no mode: \
$(grep -i '@builtin\|SNA' "$P")"
grep -q 'SNA' "$P" && fail "laptop A's own panel name leaked into the desk"
grep -q '^# hwdp-rect "@builtin" 2640 3840 2880 1800$' "$P" \
  || fail "the built-in's rect must be recorded by role"
printf 'surface chat eDP-1 cell 0 0\nsurface comms DP-1 cell 0 0 bottom\n' \
  | run surfaces --write >/dev/null || fail "surfaces --write on A failed"
grep -q '^surface chat "@builtin" cell 0 0$' "$T/surf/$desk_a.conf" \
  || fail "a surface on the built-in must name the role"
pass "laptop A files the desk by role: profile, rects and surfaces"

# --- laptop B plugs into the same desk ----------------------------------------
drm B yes
[ "$(LAPTOP=B run profile)" = "$P" ] || fail "B must find A's desk profile"
LAPTOP=B run profile --missing && fail "B's desk is not unmapped"
LAPTOP=B run layout >/dev/null 2>"$T/err" || fail "layout on B failed"
_b='    output "Dell Latitude SNB" mode 1920x1200@60.000Hz'
_b="$_b position 3120,3840 scale 1.00"
grep -qxF "$_b" "$T/out" \
  || fail "B's panel must be filled in, and re-placed CENTRED for its size: \
$(grep -i 'SNB\|@builtin' "$T/out") $(cat "$T/err")"
# Comments (the template's panel list and rects) may say @builtin; no
# DIRECTIVE may, since kanshi would look for an output by that name.
grep -v '^ *#' "$T/out" | grep -q '@builtin' \
  && fail "the role must never reach a kanshi directive: $(cat "$T/out")"
_s=$(LAPTOP=B run surfaces 2>/dev/null)
printf '%s\n' "$_s" | grep -qx 'chat eDP-1 0 0 0 0 1920 1200' \
  || fail "the built-in's surface must resolve to B's panel: $_s"
pass "laptop B gets the desk: its own panel filled in, centred, surfaces too"

# --- lid closed: the built-in switched off, on either laptop ------------------
drm A yes
LID=no run arrange DP-1 'DP-2 right-of DP-1 align bottom' >/dev/null 2>&1 \
  || fail "arrange with the lid closed failed"
grep -q '^    output "@builtin" disable$' "$P" \
  || fail "a closed lid must be the role, disabled: $(cat "$P")"
drm B yes
LAPTOP=B LID=no run layout >/dev/null 2>&1 || fail "layout on B, lid closed"
grep -q '^    output "Dell Latitude SNB" disable$' "$T/out" \
  || fail "B's panel must be the one disabled: $(cat "$T/out")"
pass "lid closed: the role is disabled, and B's panel is the one switched off"

# --- a profile filed under the exact id before desk ids is still read ---------
rm -f "$T/profiles/"*.conf
drm A yes
printf 'profile old {\n    output "Lenovo X1 SNA" disable\n}\n' \
  > "$T/profiles/$ida.conf"
[ "$(run profile)" = "$T/profiles/$ida.conf" ] \
  || fail "a legacy exact-id profile must still be read"
pass "a profile from before desk ids is still found"
