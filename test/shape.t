#!/bin/sh
# shape.t - `hwdp shape` names the KIND of desk: one token per display that is
# switched on, B(uilt-in) or E(xternal) then L(andscape) or P(ortrait) as the
# user sees it, joined with `+` and SORTED.
#
# It replaced `single | triple`, a panel COUNT, which could not tell a laptop
# from a lone external, or a landscape pair from a portrait one, while the
# grid, workspace names and wallpaper that key on it differ for each. The
# consumers build a directory name from it (~/.config/shapes/<shape>/), so the
# exact string IS the contract, and every assertion here compares it whole.
. "$(dirname "$0")/harness_lib"
harness_init shape

KA=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/drm"

# The dock target: a laptop panel, a 4K the stub can rotate, a 4K landscape.
cat > "$T/bin/wlr-randr" <<'STUB'
#!/bin/sh
_out() {   # <conn> <w> <h> <x> <transform> <enabled>
  [ "$6" = gone ] && return 0
  cat <<BLK
$1 "Acme MODEL SN-$1 ($1)"
  Make: Acme
  Model: MODEL
  Serial: SN-$1
  Physical size: 600x340 mm
  Enabled: $6
  Modes:
    ${2}x${3} px, 60.000000 Hz (preferred, current)
  Position: $4,0
  Transform: $5
  Scale: 1.000000
BLK
}
_out eDP-1 2880 1800 0    normal              "${LAPTOP:-yes}"
_out DP-1  3840 2160 2880 "${DP1_TR:-90}"     "${DP1:-yes}"
_out DP-2  3840 2160 5040 "${DP2_TR:-normal}" "${DP2:-yes}"
STUB
chmod +x "$T/bin/wlr-randr"
for _c in eDP-1 DP-1 DP-2; do
  mkdir -p "$T/drm/card1-$_c"
  printf connected > "$T/drm/card1-$_c/status"
  printf 'EDID-%s' "$_c" > "$T/drm/card1-$_c/edid"
  printf '%s\n' 2880x1800 > "$T/drm/card1-$_c/modes"
done
printf '3840x2160\n' > "$T/drm/card1-DP-1/modes"
printf '3840x2160\n' > "$T/drm/card1-DP-2/modes"

run() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY="${WL-wayland-test}" \
    HWDP_MACHINE_PROVIDERS="$T/no-machine" HWDP_PROVIDER_ROOT="$T/no-user" \
    HWDP_DRM="$T/drm" XDG_RUNTIME_DIR="$T/run" \
    LAPTOP="${LAPTOP:-yes}" DP1="${DP1:-yes}" DP2="${DP2:-yes}" \
    DP1_TR="${DP1_TR:-90}" DP2_TR="${DP2_TR:-normal}" \
    sh "$KA" shape
}
_is() {   # <label> <expected> [VAR=value ...]
  _l=$1; _e=$2; shift 2
  _g=$(env "$@" sh -c '. "$1"; run' _ "$T/run.sh")
  [ "$_g" = "$_e" ] || fail "$_l: expected '$_e', got '$_g'"
}
# run() as a file, so _is can set the stub's knobs per case.
{ printf 'T=%s; KA=%s\n' "$T" "$KA"; sed -n '/^run() {/,/^}/p' "$0"; } \
  > "$T/run.sh"

_is "the full dock, sorted B before E and L before P" BL+EL+EP
_is "built-in switched off: no B token" EL+EP LAPTOP=no
_is "a laptop on its own" BL DP1=gone DP2=gone
_is "a lone external landscape" EL LAPTOP=gone DP1=gone
_is "the rotated 4K is portrait, unrotated landscape" BL+EL+EL DP1_TR=normal
_is "a 270 rotation is portrait too" BL+EL+EP DP1_TR=270
_is "two portraits keep both tokens" BL+EP+EP DP2_TR=90
_is "one external gone" BL+EP DP2=gone
pass "the desk kind: built-in or not, orientation after rotation, sorted"

# Headless (no compositor) the kernel's native modes decide, and they carry no
# rotation: the portrait-mounted 4K reads landscape. Said, not guessed.
_is "headless reads native modes: no rotation known" BL+EL+EL WL=
pass "headless answers from the kernel, without rotation"

# Nothing switched on and nothing attached: empty, status 0.
rm -rf "$T/drm"; mkdir -p "$T/drm"
_is "no displays at all" "" LAPTOP=gone DP1=gone DP2=gone
pass "no displays is an empty answer"
