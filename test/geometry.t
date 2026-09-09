#!/bin/sh
# geometry.t - display-geometry's environment indirection: the HWDP_GEOM_BACKEND
# seam takes over wholesale, and the built-in wlr-randr backend parses the text
# into the stable line contract. Both run against stubs, no compositor needed.
. "$(dirname "$0")/lib.sh"
harness_init geometry

DG="$HERE/bin/display-geometry"

# 1) the integrator backend seam wins and gets the args passed through.
mkdir -p "$T/bin"
cat > "$T/bin/mybackend" <<'EOF'
#!/bin/sh
echo "BACKEND-RAN $*"
EOF
chmod +x "$T/bin/mybackend"
_out=$(HWDP_GEOM_BACKEND="$T/bin/mybackend" "$DG" --now 2>&1)
[ "$_out" = "BACKEND-RAN --now" ] \
  || fail "HWDP_GEOM_BACKEND seam not honoured (got: $_out)"

# 2) the built-in wlr-randr backend parses one rotated + one disabled output.
cat > "$T/bin/wlr-randr" <<'EOF'
#!/bin/sh
cat <<'OUT'
DP-1 "Dell (DP-1)"
  Enabled: yes
  Modes:
    2560x1440 px, 59.951000 Hz (preferred)
    2560x1440 px, 143.912000 Hz (current)
  Position: 0,0
  Transform: 90
  Scale: 1.000000
HDMI-A-1 "Off (HDMI-A-1)"
  Enabled: no
OUT
EOF
chmod +x "$T/bin/wlr-randr"

# 90-degree transform swaps logical w/h -> 1440x2560 portrait; disabled output
# is dropped; scale renders %g (1, not 1.000000).
_want="DP-1 2560 1440 90 1 0 0 1440 2560 portrait"
_got=$(PATH="$T/bin:$PATH" WAYLAND_DISPLAY=wayland-test DISPLAY= \
  "$DG" --now 2>&1)
[ "$_got" = "$_want" ] || fail "wlr-randr parse wrong: got [$_got]"

pass "backend seam + wlr-randr parse"
