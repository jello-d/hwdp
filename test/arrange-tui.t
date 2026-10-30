#!/bin/sh
# arrange-tui.t - the interactive layout tool, driven key by key without a
# screen: its model (rotate, swap, move), and what every key and dialog does.
#
# The curses view only draws, so everything a person decides goes through
# App.key() and App.tick(), and every call out to hwdp goes through one
# object. This drives the first with key codes and replaces the second with
# a recorder, EXCEPT the re-pack, which stays the real shell layout_repack:
# the arithmetic under test is hwdp's own, not a stand-in for it.
. "$(dirname "$0")/harness_lib"
harness_init arrange-tui
command -v python3 >/dev/null 2>&1 || skip "python3 not installed"

_out=$(python3 -I - "$HERE" 2>&1 <<'PY'
import curses, importlib.machinery, importlib.util, sys
here = sys.argv[1]
loader = importlib.machinery.SourceFileLoader(
    "tui", here + "/libexec/arrange-tui")
spec = importlib.util.spec_from_loader("tui", loader)
tui = importlib.util.module_from_spec(spec)
loader.exec_module(tui)
real = tui.Hwdp()
real.lib = here + "/lib"

fails = []
def check(label, cond, detail=""):
    if not cond:
        fails.append("%s %s" % (label, detail))

class FakeHw:
    def __init__(self):
        self.calls, self.rc, self.ident = [], {}, False
    def last(self):
        """The newest call, or an empty one: a broken tool must FAIL a
        check, not crash the script before it can report anything."""
        return self.calls[-1] if self.calls else (None, None)
    def repack(self, old, new):
        return real.repack(old, new)
    def arrange(self, mode, placements):
        self.calls.append((mode, list(placements)))
        return self.rc.get(mode, 0), "said no" if self.rc.get(mode) else ""
    def identify(self, on):
        self.ident = on
        self.calls.append(("identify", on))
        return on

def desk():
    """A 4K portrait (DP-1, rotated) with a 4K landscape right of it."""
    hw = FakeHw()
    outs = [tui.Output("DP-1", "90", 0, 0, 2160, 3840),
            tui.Output("DP-2", "normal", 2160, 0, 3840, 2160)]
    d = tui.Desk(outs, hw.repack)
    return d, outs, hw

# --- the model ----------------------------------------------------------------
d, (p, l), hw = desk()
d.rotate(p)        # 90 -> 180: landscape now, and DP-2 follows its edge
check("rotate makes the portrait landscape", (p.w, p.h) == (3840, 2160),
      (p.w, p.h))
check("rotate re-packs the neighbour onto the new edge",
      (l.x, l.y) == (3840, 0), (l.x, l.y))
check("a rotated desk is sound", not d.faults())

d, (p, l), hw = desk()
d.swap(p, l)
check("swap trades places at their own sizes",
      (l.x, l.y, p.x, p.y) == (0, 0, 3840, 0), (l.x, l.y, p.x, p.y))

d, (p, l), hw = desk()
tui.step(d, l, 0, 270)
check("a coarse step slides along the edge", (l.x, l.y) == (2160, 270),
      (l.x, l.y))
tui.step(d, l, 0, 1)
check("a fine step is one pixel", l.y == 271, l.y)
for _ in range(40):
    tui.step(d, l, 0, 270)
check("sliding off the end snaps back to touching",
      not d.faults() and tui.touches(l.rect(), p.rect()), l.rect())

d, (p, l), hw = desk()
tui.step(d, l, -480, 0)
check("moving INTO a neighbour jumps to its far side",
      (l.x, p.x) == (0, 3840) and not d.faults(), (l.x, p.x))
check("placements say where everything is",
      d.placements() == ["DP-1 rotate 90 at 3840,0",
                         "DP-2 rotate 0 at 0,0"], d.placements())

# --- the controller -----------------------------------------------------------
def app():
    d, outs, hw = desk()
    return tui.App(d, hw), outs, hw

a, (p, l), hw = app()
a.key(9, 0)
check("Tab selects the next monitor", a.cur is l)
a.key(curses.KEY_LEFT, 0)
check("an arrow selects the monitor that way", a.cur is p)

a, (p, l), hw = app()
a.key(ord("m"), 0); a.key(curses.KEY_DOWN, 0)
check("move mode: an arrow moves the selection a coarse step (h/8)",
      (p.x, p.y, l.x, l.y) == (0, 480, 2160, 0), (p.rect(), l.rect()))
a.key(curses.KEY_SF, 0)
check("move mode: shift+arrow moves one pixel", p.y == 481, p.y)
a.key(27, 0)
check("Esc in move mode undoes the move", (p.x, p.y) == (0, 0)
      and a.moving is None, (p.x, p.y))

a, (p, l), hw = app()
a.key(ord("q"), 0)
check("q with nothing changed just quits", a.done and a.dialog is None)

a, (p, l), hw = app()
a.key(ord("r"), 0)
a.key(ord("q"), 0)
check("q with changes asks first", not a.done and a.dialog[0] == "quit")
a.key(27, 0)
check("Esc in that dialog goes back", a.dialog is None and not a.done)
a.key(10, 0)
check("Enter asks how to save", a.dialog[0] == "save")
a.key(ord("c"), 0)
check("save and continue saves through arrange and stays",
      hw.last()[0] is None and not a.done and not a.dirty(), hw.calls)
a.key(ord("r"), 0); a.key(10, 0); a.key(ord("s"), 0)
check("save and exit saves and ends", a.done and not a.dirty())

a, (p, l), hw = app()
hw.rc[None] = 2
a.key(ord("r"), 0); a.key(10, 0); a.key(ord("s"), 0)
check("a refused save stays, and says why", not a.done and a.dirty()
      and a.msg == "said no", a.msg)

a, (p, l), hw = app()
a.key(ord("r"), 0); a.key(ord("p"), 100.0)
check("p previews through arrange --preview",
      hw.last()[0] == "--preview" and a.dialog[0] == "keep", hw.calls)
a.tick(100.0 + tui.PREVIEW_SECONDS - 1)
check("the countdown has not run out yet", a.dialog is not None)
a.tick(100.0 + tui.PREVIEW_SECONDS)
check("no answer reverts", hw.last()[0] == "--revert"
      and a.dialog is None, hw.calls)

a, (p, l), hw = app()
a.key(ord("r"), 0); a.key(ord("p"), 0); a.key(ord("y"), 1)
check("keeping a preview leaves it live, unsaved", a.live_unsaved
      and a.dialog is None)
a.key(ord("q"), 2); a.key(ord("q"), 2)
check("quitting with a kept preview reverts it first",
      a.done and hw.last()[0] == "--revert", hw.calls)

a, (p, l), hw = app()
hw.rc["--preview"] = 5
a.key(ord("p"), 0)
check("a preview with no supervisor says so", a.dialog is None
      and a.msg == "said no", a.msg)

a, (p, l), hw = app()
a.key(ord("i"), 0)
check("i turns the labels on", a.ident and hw.last() == ("identify", True))
a.key(ord("i"), 0)
check("i again turns them off", not a.ident
      and hw.last() == ("identify", False))

a, (p, l), hw = app()
a.key(ord("o"), 0)
check("o switches one off", not p.on and l.on)
check("its placement says off", "DP-1 off" in a.desk.placements())
a.key(9, 0); a.key(ord("o"), 0)
check("the last one on cannot be switched off", l.on, a.msg)

a, (p, l), hw = app()
a.key(ord("s"), 0); a.key(9, 0); a.key(ord("s"), 0)
check("s, select, s swaps", (l.x, p.x) == (0, 3840) and a.mark is None,
      (l.x, p.x))

print("\n".join(fails) if fails else "ALL-OK")
PY
)
[ "$_out" = ALL-OK ] || fail "$_out"
pass "model and controller: rotate, swap, move, dialogs, preview, identify"

# --- it refuses to run without a terminal -------------------------------------
if _o=$(python3 "$HERE/libexec/arrange-tui" </dev/null 2>&1); then
  fail "the tool ran with no terminal"
fi
case $_o in
  *"needs a terminal"*) ;;
  *) fail "no terminal: $_o" ;;
esac
pass "without a terminal it says so"
