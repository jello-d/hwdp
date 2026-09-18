#!/bin/sh
# geometry.t - `hwdp geometry` as a projection of the shared layout probe: the
# HWDP_GEOM_BACKEND seam is tried first, and the shipped wlr-randr provider
# parses the text into the stable line contract. Stubs only, no compositor.
. "$(dirname "$0")/lib.sh"
harness_init geometry

DG="$HERE/bin/hwdp"

# Hermetic: point the user and machine provider roots at empty dirs, so a
# provider the DEVELOPER has dropped into ~/.config/hwdp can never quietly take
# over a test run and make it pass (or fail) for the wrong reason.
export HWDP_PROVIDER_ROOT="$T/no-user-providers"
export HWDP_MACHINE_PROVIDERS="$T/no-machine-providers"

# 1) the integrator backend seam is tried first and speaks the shared LAYOUT
# record, which `hwdp geometry` projects onto its line contract: scale 2
# halves a 3840x2160 mode to a 1920x1080 logical size.
#
# The line ends with the panel's PHYSICAL size, 600x340mm here, straight from
# the provider record's mm fields. It is APPENDED rather than inserted so every
# existing consumer's field numbers still hold -- wb reads 1/6/8/9, run-scaled
# 2/3, the slicer 1/6/7/8/9 -- and a consumer wanting millimetres reads 11/12.
mkdir -p "$T/bin"
cat > "$T/bin/mybackend" <<'EOF'
#!/bin/sh
printf 'Acme X1 S1\tDP-9\t3840\t2160\t600\t340\t60\tnormal\t2\t10\t20\t1\n'
EOF
chmod +x "$T/bin/mybackend"
_out=$(HWDP_GEOM_BACKEND="$T/bin/mybackend" "$DG" geometry --now 2>&1)
[ "$_out" = "DP-9 3840 2160 normal 2 10 20 1920 1080 landscape 600 340" ] \
  || fail "HWDP_GEOM_BACKEND seam not honoured (got: $_out)"

# 2) the built-in wlr-randr backend parses a rotated output (separate preferred
# + current lines), a COMBINED-flag output (one mode that is "(preferred,
# current)" -- the real wlr-randr form when the current mode is also preferred,
# which a bare /\(current\)/ match missed), and a disabled output (dropped).
cat > "$T/bin/wlr-randr" <<'EOF'
#!/bin/sh
cat <<'OUT'
DP-1 "Dell (DP-1)"
  Physical size: 600x340 mm
  Enabled: yes
  Modes:
    2560x1440 px, 59.951000 Hz (preferred)
    2560x1440 px, 143.912000 Hz (current)
  Position: 0,0
  Transform: 90
  Scale: 1.000000
DP-2 "HP (DP-2)"
  Physical size: 530x300 mm
  Enabled: yes
  Modes:
    1920x1080 px, 60.000000 Hz (preferred, current)
  Position: 2560,0
  Transform: normal
  Scale: 1.000000
HDMI-A-1 "Off (HDMI-A-1)"
  Enabled: no
OUT
EOF
chmod +x "$T/bin/wlr-randr"

# DP-1: 90-degree transform swaps logical w/h -> 1440x2560 portrait; scale
# renders %g (1, not 1.000000). DP-2: the combined-flag mode is picked as
# current. HDMI-A-1 disabled -> dropped.
#
# The trailing millimetres SWAP WITH THE ROTATION too (600x340 -> 340x600 on
# DP-1): the EDID describes the panel, so once it is turned on its side the
# physical width is what the logical width now spans. A consumer laying an
# image out in millimetres across a mixed-orientation desk gets this wrong in a
# way that is invisible on a landscape-only rig.
_want="DP-1 2560 1440 90 1 0 0 1440 2560 portrait 340 600
DP-2 1920 1080 normal 1 2560 0 1920 1080 landscape 530 300"
_got=$(PATH="$T/bin:$PATH" WAYLAND_DISPLAY=wayland-test DISPLAY= \
  "$DG" geometry --now 2>&1)
[ "$_got" = "$_want" ] || fail "wlr-randr parse wrong: got [$_got]"

pass "backend seam + wlr-randr parse"
