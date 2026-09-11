#!/bin/sh
# probe.t - the shared probe layer: provider PRECEDENCE, the fail-soft CASCADE,
# and the headless regression the whole split exists to kill.
#
# The bug, found live on manifestor at its greeter: `uiprofile` asked a LAYOUT
# question (wlr-randr) to decide a PANEL fact (how big is this screen), got
# nothing because no compositor was up, and fell silently through to its hidpi
# else -- reporting CURSOR_SIZE=48 for a 1920x1080 panel whose answer is 32.
. "$(dirname "$0")/lib.sh"
harness_init probe

KA="$HERE/bin/hwdp"
mkdir -p "$T/bin" "$T/home" "$T/user/layout" "$T/machine/layout" "$T/drm"

# A fake DRM tree: one connected 1920x1080 panel, one disconnected connector.
mk_conn() {   # <connector> <status> <edid> [modes]
  mkdir -p "$T/drm/$1"
  printf '%s\n' "$2" > "$T/drm/$1/status"
  printf '%s' "$3" > "$T/drm/$1/edid"
  [ -n "${4:-}" ] && printf '%s\n' "$4" > "$T/drm/$1/modes"
  return 0
}
mk_conn card1-DP-2 connected    EDID-PANEL-A 1920x1080
mk_conn card1-DP-3 disconnected ''

run() {   # kanshi-autoscale with NO compositor: no WAYLAND_DISPLAY, no DISPLAY
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    HWDP_DRM="$T/drm" HWDP_PROVIDER_ROOT="$T/user" \
    HWDP_MACHINE_PROVIDERS="$T/machine" \
    KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
    KANSHI_OUT="$T/out" sh "$KA" "$@"
}

# --- the regression: headless, the PANEL class still answers -----------------
# No layout provider can answer (no compositor), so shape and the density test
# must come from DRM sysfs rather than falling through to hidpi.
[ "$(run shape)" = single ] || fail "shape did not fall back to panels headless"

_ui=$(run ui) || fail "uiprofile failed headless: $_ui"
_cs=$(printf '%s\n' "$_ui" | sed -n 's/^CURSOR_SIZE=//p')
[ "$_cs" = 32 ] \
  || fail "headless uiprofile sized for hidpi (CURSOR_SIZE=$_cs, want 32)"

# The HWDP id resolves headless too -- this is the probe the greeter is chosen
# by, at provision time from a TTY, so it must never need a session.
case "$(run id)" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) fail "hwdp id did not resolve headless" ;;
esac

# --- with NOTHING connected, uiprofile refuses rather than guessing -----------
mkdir -p "$T/drm-empty"
_out=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
  HWDP_DRM="$T/drm-empty" HWDP_PROVIDER_ROOT="$T/user" \
  HWDP_MACHINE_PROVIDERS="$T/machine" sh "$KA" ui 2>/dev/null) \
  && fail "uiprofile invented a UI size with no displays at all"
[ -z "$_out" ] || fail "uiprofile emitted keys with no displays: $_out"

# --- precedence: user root beats machine root beats shipped ------------------
cat > "$T/machine/layout/10-src" <<'EOF'
#!/bin/sh
printf 'M M M\tDP-M\t1920\t1080\t500\t280\t60\tnormal\t1\t0\t0\t1\n'
EOF
cat > "$T/user/layout/10-src" <<'EOF'
#!/bin/sh
printf 'U U U\tDP-U\t1920\t1080\t500\t280\t60\tnormal\t1\t0\t0\t1\n'
EOF
chmod +x "$T/machine/layout/10-src" "$T/user/layout/10-src"

_dg() { env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
  HWDP_PROVIDER_ROOT="$T/user" HWDP_MACHINE_PROVIDERS="$T/machine" \
  sh "$HERE/bin/hwdp" geometry --now 2>&1; }

[ "$(_dg | cut -d' ' -f1)" = DP-U ] \
  || fail "user provider did not win over machine ($(_dg))"

rm -f "$T/user/layout/10-src"
[ "$(_dg | cut -d' ' -f1)" = DP-M ] \
  || fail "machine provider did not win over shipped ($(_dg))"

# --- cascade: a provider that cannot answer is SKIPPED, not fatal ------------
# 05 sorts first and abstains (exit 1, the "not my environment" contract); 10
# abstains by printing nothing at all. The answer must come from 20.
cat > "$T/user/layout/05-abstains" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$T/user/layout/10-silent" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/user/layout/20-answers" <<'EOF'
#!/bin/sh
printf 'A A A\tDP-A\t1920\t1080\t500\t280\t60\tnormal\t1\t0\t0\t1\n'
EOF
chmod +x "$T/user/layout/05-abstains" "$T/user/layout/10-silent" \
  "$T/user/layout/20-answers"
[ "$(_dg | cut -d' ' -f1)" = DP-A ] \
  || fail "cascade did not skip the abstaining providers ($(_dg))"

pass "provider precedence + cascade + headless panel fallback"
