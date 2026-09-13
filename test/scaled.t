#!/bin/sh
# scaled.t - run-scaled's argument handling and the command it BUILDS.
#
# The last shipped command without a test, and the one reported as misbehaving.
# It cannot be tested by running it -- it EXECs gamescope and becomes the child
# process -- so the thing to assert is the argv it assembles. A stub gamescope
# that prints its own arguments turns an unrunnable exec into a readable value.
#
# What that covers, all of it reported or plausible misbehaviour:
#   the render size is box/scale, so a wrong scale is a wrong render
#   --fullscreen takes the box from `hwdp geometry`, the one behaviour that
#     CHANGED rather than moved when this stopped parsing displays itself
#   the child gets X11 toolkit hints unless --wayland-app, which is what keeps
#     a Qt or GTK app from chasing a nested Wayland the sandbox does not expose
#   a bad --filter is refused rather than passed through to gamescope
. "$(dirname "$0")/lib.sh"
harness_init scaled

RS=$HERE/bin/run-scaled
mkdir -p "$T/bin"

# gamescope, as an echo of its own argv. `exec` means run-scaled BECOMES this,
# so its stdout is the whole observable result.
cat > "$T/bin/gamescope" <<'EOF'
#!/bin/sh
printf '%s\n' "$*"
EOF
# hwdp, answering only `geometry` -- the fullscreen box comes from field 2/3.
cat > "$T/bin/hwdp" <<'EOF'
#!/bin/sh
[ "$1" = geometry ] || exit 1
echo "eDP-1 2880 1800 normal 1 0 0 2880 1800 landscape"
EOF
cat > "$T/bin/bc" <<'EOF'
#!/bin/sh
exec /usr/bin/bc "$@"
EOF
chmod +x "$T/bin/gamescope" "$T/bin/hwdp" "$T/bin/bc"
command -v bc >/dev/null 2>&1 || skip "bc not installed (run-scaled needs it)"

# Executed directly, not via `sh`: run-scaled is the one bash file here (it
# uses arrays and herestrings), and `sh` on it is a syntax error.
run() { PATH="$T/bin:$PATH" "$RS" "$@" 2>&1; }

# --- defaults: 1280x800 box, scale 2 -> 640x400 render ----------------------
_o=$(run /usr/bin/true) || fail "default invocation failed: $_o"
case $_o in
  *"-w 640 -h 400 -W 1280 -H 800"*) ;;
  *) fail "default box/render wrong: $_o" ;;
esac
case $_o in *" -b "*) ;; *) fail "windowed mode should pass -b: $_o" ;; esac

# --- --scale divides the render size, and a trailing x is tolerated ---------
_o=$(run --scale=4 /usr/bin/true)
case $_o in
  *"-w 320 -h 200 -W 1280 -H 800"*) ;;
  *) fail "--scale=4 did not divide the render size: $_o" ;;
esac
_o=$(run --scale=4x /usr/bin/true)
case $_o in
  *"-w 320 -h 200"*) ;;
  *) fail "--scale=4x (trailing x) not tolerated: $_o" ;;
esac

# --- --size sets the box ----------------------------------------------------
_o=$(run --size=1920x1080 --scale=2 /usr/bin/true)
case $_o in
  *"-w 960 -h 540 -W 1920 -H 1080"*) ;;
  *) fail "--size did not set the box: $_o" ;;
esac

# --- --fullscreen takes the box from `hwdp geometry` ------------------------
# The behaviour that CHANGED: this used to parse wlr-randr/xrandr itself.
_o=$(run --fullscreen --scale=2 /usr/bin/true)
case $_o in
  *"-w 1440 -h 900 -W 2880 -H 1800"*) ;;
  *) fail "--fullscreen did not size from hwdp geometry: $_o" ;;
esac
case $_o in *" -f "*) ;; *) fail "--fullscreen should pass -f: $_o" ;; esac

# --- fullscreen with NO geometry answer refuses, rather than guessing -------
cat > "$T/bin/hwdp" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$T/bin/hwdp"
_o=$(run --fullscreen /usr/bin/true) && fail "fullscreen invented a box with \
no geometry: $_o"
case $_o in
  *"could not detect output"*) ;;
  *) fail "fullscreen failure should say so: $_o" ;;
esac
cat > "$T/bin/hwdp" <<'EOF'
#!/bin/sh
[ "$1" = geometry ] || exit 1
echo "eDP-1 2880 1800 normal 1 0 0 2880 1800 landscape"
EOF
chmod +x "$T/bin/hwdp"

# --- filters map to gamescope flags, and an unknown one is REFUSED ----------
_o=$(run --filter=nearest /usr/bin/true)
case $_o in *" -n "*) ;; *) fail "--filter=nearest should pass -n: $_o" ;; esac
_o=$(run --filter=fsr /usr/bin/true)
case $_o in
  *"-F fsr"*) ;;
  *) fail "--filter=fsr should pass -F fsr: $_o" ;;
esac
_o=$(run --filter=bogus /usr/bin/true) && fail "an unknown filter was accepted"
case $_o in
  *"unknown --filter"*) ;;
  *) fail "unknown filter should say so: $_o" ;;
esac

# --- the child's toolkit hints ----------------------------------------------
# Without them a Qt/GTK/SDL app inside gamescope's Xwayland chases the outer
# Wayland display and either fails or escapes the sandbox.
_o=$(run /usr/bin/true)
case $_o in
  *"QT_QPA_PLATFORM=xcb"*) ;;
  *) fail "the child did not get X11 toolkit hints: $_o" ;;
esac
_o=$(run --wayland-app /usr/bin/true)
case $_o in
  *"QT_QPA_PLATFORM=xcb"*) fail "--wayland-app must NOT force X11 hints: $_o" ;;
esac
case $_o in
  *"--expose-wayland"*) ;;
  *) fail "--wayland-app should pass --expose-wayland: $_o" ;;
esac

# --- bad numbers are REFUSED, not handed to gamescope -----------------------
# All three of these were found by writing this test. --scale=0 and a typo like
# --scale=abc (bc reads it as 0) died with a bare "Divide by zero" from bc, and
# --size=bogus went all the way through to `gamescope -W bogus -H bogus`.
for _bad in 0 abc -2 . ''; do
  _o=$(run --scale="$_bad" /usr/bin/true) \
    && fail "--scale='$_bad' was accepted: $_o"
  case $_o in
    *"run-scaled: --scale"*) ;;
    *) fail "--scale='$_bad' did not fail with our own message: $_o" ;;
  esac
done
for _bad in bogus 1920x 'x1080' '1920X1080' '1920x1080x'; do
  _o=$(run --size="$_bad" /usr/bin/true) \
    && fail "--size='$_bad' was accepted: $_o"
  case $_o in
    *"run-scaled: --size"*) ;;
    *) fail "--size='$_bad' did not fail with our own message: $_o" ;;
  esac
done
# A fractional scale is legitimate and must still work.
_o=$(run --scale=1.5 /usr/bin/true) || fail "--scale=1.5 rejected: $_o"
case $_o in
  *"-w 853 -h 533"*) ;;
  *) fail "--scale=1.5 computed the wrong render size: $_o" ;;
esac
# --size is irrelevant under --fullscreen, so it must not be validated there.
_o=$(run --fullscreen --size=bogus /usr/bin/true) \
  || fail "--fullscreen rejected an unused --size: $_o"

# --- --native: say what the app needs, not what is left over ----------------
# The bug this exists for: tt asked for --scale=3 in the default 1280x800
# window, so tuxtype got a 426x266 canvas, drew its fixed 640x480 layout into
# it, lost two menu items and half the title off the edges, and the CLIP was
# what got magnified. Reported as "the window is fighting the scale", which is
# exactly what a magnified crop looks like.
_o=$(run --native=640x480 --scale=3 /usr/bin/true) \
  || fail "--native rejected: $_o"
case $_o in
  *"-w 640 -h 480 -W 1920 -H 1440"*) ;;
  *) fail "--native did not make the window native*scale: $_o" ;;
esac
# The canvas comes back out as EXACTLY the native size, which is the whole
# point -- an off-by-rounding here would clip the app again, quietly.
_o=$(run --native=800x600 --scale=2 /usr/bin/true)
case $_o in
  *"-w 800 -h 600 -W 1600 -H 1200"*) ;;
  *) fail "--native canvas is not the native size: $_o" ;;
esac

# A too-small canvas WARNS. Not fails: plenty of apps are happy small, and
# refusing would be this tool deciding it knows better. But silence is how the
# original bug survived.
_o=$(run --scale=3 /usr/bin/true)
case $_o in
  *"under 640x480"*) ;;
  *) fail "a 426x266 canvas did not warn: $_o" ;;
esac
case $_o in
  *"--native"*) ;;
  *) fail "the warning should point at --native: $_o" ;;
esac
# ...and it is a warning, so the app still runs.
case $_o in
  *"-W 1280 -H 800"*) ;;
  *) fail "the canvas warning must not stop the launch: $_o" ;;
esac
# A big enough canvas stays quiet.
_o=$(run --native=640x480 --scale=3 /usr/bin/true)
case $_o in
  *"under"*) fail "a native-sized canvas should not warn: $_o" ;;
esac

# Both ways of setting the window at once is a REFUSAL, not a silent winner.
_o=$(run --native=640x480 --size=800x600 /usr/bin/true) \
  && fail "--native with --size was accepted"
case $_o in
  *"give one"*) ;;
  *) fail "--native + --size should say why: $_o" ;;
esac
_o=$(run --native=640x480 --fullscreen /usr/bin/true) \
  && fail "--native with --fullscreen was accepted"
_o=$(run --native=bogus /usr/bin/true) && fail "--native=bogus was accepted"

# --- gamescope is found OUTSIDE PATH ----------------------------------------
# Debian ships gamescope in /usr/games, which a login shell has and a launcher
# does not: a compositor keybind or a .desktop entry runs with
# /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin. Trusting PATH
# alone made "works when I type it, fails from the menu" the same install.
mkdir -p "$T/games"
mv "$T/bin/gamescope" "$T/games/gamescope"
# A LAUNCHER's PATH, not this shell's -- the developer's interactive PATH has
# /usr/games in it and would quietly find the REAL gamescope, which is both a
# false pass and a window on someone's screen.
_lp=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
_o=$(PATH="$_lp" GAMESCOPE_DIRS="$T/games" "$RS" /usr/bin/true 2>&1) \
  || fail "gamescope in a games dir was not found: $_o"
case $_o in
  *"-W 1280 -H 800"*) ;;
  *) fail "the out-of-PATH gamescope was not the one run: $_o" ;;
esac

# Nowhere at all is a clear refusal, not a confusing failure from gamescope.
_o=$(PATH="$_lp" GAMESCOPE_DIRS="$T/nowhere" "$RS" /usr/bin/true 2>&1) \
  && fail "ran with no gamescope anywhere: $_o"
case $_o in
  *"gamescope not found"*) ;;
  *) fail "missing gamescope should say so: $_o" ;;
esac
mv "$T/games/gamescope" "$T/bin/gamescope"

# --- usage errors -----------------------------------------------------------
run > /dev/null 2>&1 && fail "no arguments should exit non-zero"
_o=$(run --scale=2) && fail "no application should exit non-zero"
case $_o in
  *"No application given"*) ;;
  *) fail "missing application should say so: $_o" ;;
esac
_o=$(run --bogus-flag /usr/bin/true) && fail "an unknown flag was accepted"

pass "argv assembly, fullscreen box, filters, toolkit hints"
