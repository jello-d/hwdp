#!/bin/sh
# desk-gtk.t - `hwdp gdesk`, the desk tool in a window, and the pointer half
# of the controller it shares with the terminal tool.
#
# Three tiers. The POINTER (grab, drag, drop) and the toolkit's key names are
# the shared core's, so they are pinned without any toolkit. The window's
# frame (logical pixels to widget pixels, and back for a click) is pure too.
# Then the REAL window, in a headless sway of its own (its own runtime dir,
# so it can never reach the session running this), driven through its own
# handlers: a drag, a key, the preview's keep dialog, a failed save's error
# dialog, and the quit prompt. Every call out to hwdp is a recorder, except
# the re-pack, which is the real shell layout_repack.
. "$(dirname "$0")/harness_lib"
harness_init desk-gtk
command -v python3 >/dev/null 2>&1 || skip "python3 not installed"

cat > "$T/common.py" <<'PY'
import curses, importlib.machinery, importlib.util, os, shutil, sys
here = sys.argv[1]
WALLS = sys.argv[2] + "/walls"
os.environ["HWDP_WALLPAPER_DIR"] = WALLS
os.environ["XDG_CACHE_HOME"] = sys.argv[2] + "/cache"
CUTTER = shutil.which("magick") or shutil.which("convert")
ld = importlib.machinery.SourceFileLoader("gui", here + "/libexec/desk-gtk")
sp = importlib.util.spec_from_loader("gui", ld)
gui = importlib.util.module_from_spec(sp)
ld.exec_module(gui)
from hwdp_desk import controller, model, hwdp
real = hwdp.Hwdp()
real.lib = here + "/lib"

fails = []
def check(label, cond, detail=""):
    if not cond:
        fails.append("%s %s" % (label, detail))

class FakeHw:
    def __init__(self):
        self.calls, self.rc, self.ident = [], {}, False
    def repack(self, old, new):
        return real.repack(old, new)
    def arrange(self, mode, placements, progress=None):
        self.calls.append((mode, list(placements)))
        return self.rc.get(mode, 0), \
            "  hwdp arrange: the REASON\nnot saved" if self.rc.get(mode) \
            else ""
    def identify(self, on):
        self.ident = on
        self.calls.append(("identify", on))
        return on
    def surfaces(self, desk):
        return [], None, ""
    def splits(self):
        return []
    def grid(self):
        return None
    namesv = [["comms", "Comms"]]
    def names(self):
        return [list(n) for n in self.namesv]
    def wallpapers(self):
        return {}
    def wallpaper_images(self):
        return ["aurora.png", "night sky.png"]
    def wallpaper_dir(self):
        return WALLS
    def slice_preview(self, walls, layout, outdir):
        self.calls.append(("preview", dict(walls)))
        return real.slice_preview(walls, layout, outdir)
    def write_names(self, names):
        self.calls.append(("names", [list(n) for n in names]))
        return 0, ""
    def write_desk(self, grid, surfaces, default, splits=()):
        self.calls.append(("desk", grid, sorted(x.key() for x in surfaces)))
        return 0, ""
    def write_wallpapers(self, walls):
        self.calls.append(("walls", dict(walls)))
        return 0, ""
    def apply(self):
        self.calls.append(("apply",))
        return 0, ""

def desk():
    """A laptop panel, a portrait 4K right of it, a 1440p right of that."""
    hw = FakeHw()
    outs = [model.Output("eDP-1", "normal", 0, 0, 1920, 1200),
            model.Output("DP-1", "90", 1920, 0, 1440, 2560),
            model.Output("DP-2", "normal", 3360, 0, 2560, 1440)]
    return model.Desk(outs, hw.repack), outs, hw

def sync(work, finish):
    return {"finish": finish, "res": work()}

def make_walls():
    """Two images for the pickers and the preview: left red, right blue;
    and a grey one."""
    import cairo
    os.makedirs(WALLS, exist_ok=True)
    for name, paint in (("aurora.png", ((1, 0, 0), (0, 0, 1))),
                        ("night sky.png", ((0.5, 0.5, 0.5),) * 2)):
        img = cairo.ImageSurface(cairo.FORMAT_RGB24, 800, 400)
        cr = cairo.Context(img)
        for i, rgb in enumerate(paint):
            cr.set_source_rgb(*rgb)
            cr.rectangle(i * 400, 0, 400, 400)
            cr.fill()
        img.write_to_png(os.path.join(WALLS, name))
PY

# --- the pointer, and the toolkit's keys: the shared core --------------------
_out=$(python3 -I - "$HERE" "$T" 2>&1 <<'PY'
import sys
exec(open(sys.argv[2] + "/common.py").read())
d, (e, p, l), hw = desk()
spot = model.drag_spot(d, l, -1000, 1300, 0)
check("a drag lands where it touches, nearest the pointer",
      spot == (-1000, 1200), spot)
spot = model.drag_spot(d, l, 1000, 1500, 0)
check("never where it would overlap: under the 4K, not the laptop",
      spot == (1000, 2560), spot)
spot = model.drag_spot(d, l, 3360, 1390, 0)
check("a drag beside a panel keeps its place along the edge",
      spot == (3360, 1390), spot)
spot = model.drag_spot(d, l, 3360, 1110, 100)
check("within reach it pulls in to the nearest alignment (bottoms)",
      spot == (3360, 1120), spot)
spot = model.drag_spot(d, l, 3360, 1000, 50)
check("out of reach it stays where it was dropped", spot == (3360, 1000),
      spot)
spot = model.drag_spot(d, l, 1500, 600, 0)
check("a drag INTO a panel lands touching it, never over it",
      spot and not any(model.overlaps((spot[0], spot[1], l.w, l.h),
                                      n.rect()) for n in (e, p)), spot)
solo = model.Desk([model.Output("eDP-1", "normal", 0, 0, 100, 100)], None)
check("a lone panel has nothing to touch",
      model.drag_spot(solo, solo.outs[0], 50, 50, 10) is None)

d, (e, p, l), hw = desk()
a = controller.App(d, hw)
check("grab takes the panel and starts a move", a.grab(2) and a.sel == 2
      and a.moving and a.moving[0] is l)
a.drag_to(-2000.4, 400.6, 0)
check("dragged left of everything it touches the laptop's left edge",
      (l.x, l.y) == (-2560, 401) and "left of eDP-1" in a.msg,
      ((l.x, l.y), a.msg))
check("the frame is not normalised mid-drag", e.x == 0, e.x)
a.drop()
check("the drop normalises, and it STAYS selected for the arrows",
      a.moving and a.moving[0] is l and l.x == 0 and e.x == 2560
      and not d.faults() and "Enter places it" in a.msg,
      (l.rect(), e.rect(), a.msg))
a.key(curses.KEY_SF, 0)
check("so an arrow after the drop nudges it", l.y == 402, l.y)
a.key(10, 0)
check("and Enter puts it down where it is", a.moving is None
      and (l.x, l.y) == (0, 402) and "placed" in a.msg, (l.rect(), a.msg))
a.grab(1)
a.drag_to(9000, 9000, 0)
a.key(27, 0)
check("Esc mid-drag undoes it, as it undoes a move",
      (p.x, p.y) == (4480, 0) and a.moving is None, p.rect())
a.drag_to(0, 0, 0)
a.drop()
check("a drag after Esc moves nothing", (p.x, p.y) == (4480, 0), p.rect())
before = [o.rect() for o in d.outs]
a.grab(1)
a.drag_to(-9000, 0, 0)
a.drop()
a.key(27, 0)
check("Esc after a drag past the left edge puts back the WHOLE desk",
      [o.rect() for o in d.outs] == before and not d.faults(),
      [o.rect() for o in d.outs])
a.grab(2)
a.drag_to(-9000, 300, 0)
a.drop()
check("a click on another monitor puts the selected one down",
      a.highlight(0) and a.moving is None and a.sel == 0
      and "placed" in a.msg, (a.moving, a.msg))
a.grab(2)
a.release()
check("and a click on nothing does too", a.moving is None)
a.desk.outs[0].on = False
check("an output that is off is selected but not grabbed",
      not a.grab(0) and a.sel == 0 and a.moving is None)
a.desk.outs[0].on = True
a.dialog = ("keep", 99)
check("nothing is grabbed while a dialog is up", not a.grab(1))

k = controller.key_code
check("arrow names are the terminal's arrows",
      k("Left", "") in controller.ARROWS and k("Down", "") in
      controller.ARROWS, (k("Left", ""), k("Down", "")))
check("shift+arrow is the fine step",
      k("Right", "", True) in controller.FINE, k("Right", "", True))
check("Return is Enter and Escape is Esc",
      k("Return", "\r") in controller.ENTER and k("Escape", "\x1b") == 27)
check("a printable key is its character", k("r", "r") == ord("r")
      and k("W", "W", True) == ord("W"))
check("an unknown key is nothing", k("F13", "") is None)
print("FAILS:" + "|".join(fails) if fails else "OK")
PY
)
case $_out in *OK) ;; *) fail "pointer: $_out" ;; esac
pass "a drag touches, aligns within reach, and Esc undoes it; keys by name"

# --- the frame: logical pixels to widget pixels, and a click back -----------
_out=$(python3 -I - "$HERE" "$T" 2>&1 <<'PY'
import sys
exec(open(sys.argv[2] + "/common.py").read())
d, (e, p, l), hw = desk()
fr = gui.frame(d.outs, 1000, 600)
s, ox, oy, mx, my = fr
check("the desk fits the width it has", abs((5920 * s) - (1000 - 64)) < 1e-6,
      fr)
x, y, w, h = gui.box(p, fr)
check("a box is the output to scale", abs(w - 1440 * s) < 1e-9
      and abs(x - (ox + 1920 * s)) < 1e-9, (x, w))
check("a click inside a box is that output",
      gui.hit(d.outs, fr, 1000, 600, x + w / 2, y + h / 2) == 1)
check("a click between boxes is nothing",
      gui.hit(d.outs, fr, 1000, 600, 2, 2) is None)
fr = gui.frame(d.outs, 1000, 600, room=l)
inside = []
for px, py in ((-9e4, -9e4), (9e4, -9e4), (-9e4, 9e4), (9e4, 9e4),
               (0, 9e4), (9e4, 0), (-9e4, 600), (2000, -9e4)):
    sx, sy = model.drag_spot(d, l, px, py, 0)
    l.x, l.y = sx, sy
    x, y, w, h = gui.box(l, fr)
    inside.append(x >= 0 and y >= 0 and x + w <= 1000 and y + h <= 600)
l.x, l.y = 3360, 0
check("a drag's frame holds every place the drop can land",
      all(inside), inside)
e.on = False
fr = gui.frame(d.outs, 1000, 600)
(i, (tx, ty, tw, th)), = gui.tray_boxes(d.outs, 1000, 600)
check("an output that is off goes to the tray, under the drawing",
      i == 0 and ty >= 600 - 64 >= gui.box(l, fr)[1] + gui.box(l, fr)[3],
      (i, ty))
check("a click in the tray is that output",
      gui.hit(d.outs, fr, 1000, 600, tx + 5, ty + 5) == 0)
e.on = True
check("a sound desk has no warning", gui.banner_text(d) == "")
# Both on A's right, B above C with a strip of 30 between them: every
# panel touches something, and two face each other across a gap.
near = model.Desk([model.Output("A", "normal", 0, 0, 1000, 2000),
                   model.Output("B", "normal", 1000, 0, 1000, 1000),
                   model.Output("C", "normal", 1000, 1030, 1000, 970)], None)
check("a near miss is said in the terminal tool's words",
      gui.banner_text(near) == "30px gap between B and C (the pointer"
      " cannot cross it)", gui.banner_text(near))
l.x += 30
check("a desk that does not meet is said so",
      gui.banner_text(d) == "the monitors do not meet edge to edge")

# The virtual tab's frame: a spot found by where it is drawn.
d, (e, p, l), hw = desk()
a = controller.App(d, hw)
vf = gui.vframe(a, 1200, 700)
b = gui.vbox(vf, 1, 0, l)
check("a click on a panel in a cell is that panel, whole",
      gui.vhit(a, 1200, 700, b[0] + b[2] / 2, b[1] + b[3] / 2)
      == (1, 0, l, "full"))
a.splits[("DP-2", 1, 0)] = "top-bottom"
check("cut in that cell, the upper part is its top",
      gui.vhit(a, 1200, 700, b[0] + 5, b[1] + 5) == (1, 0, l, "top"))
check("and the lower part its bottom",
      gui.vhit(a, 1200, 700, b[0] + 5, b[1] + b[3] - 5)
      == (1, 0, l, "bottom"))
c = gui.cell_rect(vf, 2, 2)
check("a click in a cell between panels is the cell alone",
      gui.vhit(a, 1200, 700, c[0] + 2, c[1] + 2) == (2, 2, None, None))
check("a click outside every cell is nothing",
      gui.vhit(a, 1200, 700, 1, 1) is None)
inner = all(gui.vbox(vf, cx, cy, o)[0] >= gui.cell_rect(vf, cx, cy)[0]
            and gui.vbox(vf, cx, cy, o)[0] + gui.vbox(vf, cx, cy, o)[2]
            <= gui.cell_rect(vf, cx, cy)[0] + gui.cell_rect(vf, cx, cy)[2]
            for cx in range(3) for cy in range(3) for o in d.on())
check("every miniature sits inside its own cell", inner)

# The slicer's view of the desk as edited: edges kept, millimetres turned.
o1 = model.Output("A", "normal", 0, 0, 1921, 1081)
o2 = model.Output("Dell Inc. P2721Q", "90", 1921, 0, 1081, 1921)
o1.set_mm(600, 340)
o2.set_mm(340, 600)          # as geometry gives a quarter-turned panel
f = [ln.split() for ln in model.slicer_layout(model.Desk([o1, o2], None),
                                               1000)]
check("a slicer layout has the geometry's twelve fields",
      all(len(x) == 12 for x in f), f)
check("a name with spaces is one field, the manifest's name for it",
      f[1][0] == model.slicer_name(o2) == "Dell_Inc._P2721Q", f[1][0])
check("touching outputs still touch after the scale",
      int(f[0][5]) + int(f[0][7]) == int(f[1][5]), f)
# Three of 1001 at 1000 across: rounding SIZES would leave the third a
# pixel off the second (333 + 333 = 666, but 2002 scaled is 667).
tri = model.Desk([model.Output("T%d" % i, "normal", i * 1001, 0, 1001, 500)
                  for i in range(3)], None)
t = [ln.split() for ln in model.slicer_layout(tri, 1000)]
check("every shared edge survives the scale, not just the first",
      all(int(t[i][5]) + int(t[i][7]) == int(t[i + 1][5]) for i in (0, 1)),
      t)
check("the desk is the width asked for",
      int(f[1][5]) + int(f[1][7]) == 1000, f)
check("a quarter-turned panel's millimetres are turned too",
      f[1][10:12] == ["340", "600"], f[1])
o2.transform = "normal"
check("and turned back with it", o2.mm() == (600, 340), o2.mm())

# The name form, filled in whole: refused characters are said.
a._name_add(0)
a.form_submit("mail!", "Mail")
check("a name with a character typing refuses is refused, and says it",
      a.dialog and "not !" in a.form["err"], a.form)
a.form_submit("mail", "Mäil")
check("a label that is not plain ASCII is refused, and says it",
      a.dialog and "not ä" in a.form["err"], a.form)
a.form_submit("mail", "")
check("a good name is added, its label the name when blank",
      not a.dialog and ["mail", "mail"] in a.names, a.names)
a.select_spot(1, 0, l, "bottom")
check("select_spot takes a cell, a panel and a half",
      a.vcell == [1, 0] and a.vspot() == (l, "bottom"), a.vspot())
a.select_spot(2, 2, None, None)
check("with no panel it takes the cell alone",
      a.vcell == [2, 2] and a.vspot()[0] is l)
a.place("mail")
check("place puts a name on the selected spot",
      [x.key() for x in a.surfaces] ==
      [model.Surface("mail", "DP-2", "full", 2, 2).key()], a.surfaces)
print("FAILS:" + "|".join(fails) if fails else "OK")
PY
)
case $_out in *OK) ;; *) fail "frame: $_out" ;; esac
pass "the frames: the desk fitted, a click finds its output, spot and half"

# --- the real window, in a headless sway of its own -------------------------
command -v sway >/dev/null 2>&1 || { pass "window not run (no sway)"; exit 0; }
python3 -c 'import gi; gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1"); from gi.repository import Adw' 2>/dev/null \
  || { pass "window not run (no GTK 4 + libadwaita bindings)"; exit 0; }
mkdir -p "$T/run"
chmod 700 "$T/run"
: > "$T/sway.conf"
( export XDG_RUNTIME_DIR="$T/run" SWAYSOCK="$T/run/sway.sock" \
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
  unset WAYLAND_DISPLAY DISPLAY WAYFIRE_SOCKET
  exec sway -c "$T/sway.conf" >"$T/sway.log" 2>&1 ) &
_sway=$!
harness_cleanup "kill $_sway 2>/dev/null"
_i=0
until _wl=$(cd "$T/run" && ls wayland-[0-9] 2>/dev/null | head -1) \
    && [ -n "$_wl" ]; do
  _i=$((_i + 1))
  [ "$_i" -lt 50 ] || fail "headless sway did not start: $(tail -3 \
    "$T/sway.log")"
  sleep 0.2
done
_out=$(env -i PATH=/usr/bin:/bin HOME="$T/home" XDG_RUNTIME_DIR="$T/run" \
  WAYLAND_DISPLAY="$_wl" GSK_RENDERER=cairo GDK_BACKEND=wayland \
  timeout 60 python3 -I - "$HERE" "$T" 2>&1 <<'PY'
import sys, time
exec(open(sys.argv[2] + "/common.py").read())
from gi.repository import Adw, Gdk, Gio, GLib

class Gesture:
    denied = False
    def set_state(self, s):
        self.denied = True

def key(w, keyval):
    return w.on_key(None, keyval, 0, 0)

def drive(w, a, hw, d, outs):
    e, p, l = outs
    v = w.view
    v.area.set_size_request(1000, 600)
    while v.area.get_width() == 0:
        yield
    fr = v.fr()
    x, y, bw, bh = gui.box(l, fr)
    g = Gesture()
    v.on_begin(g, x + bw / 2, y + bh / 2)
    check("a press on a panel highlights it, and selects nothing",
          not g.denied and a.sel == 2 and a.moving is None, a.moving)
    v.on_update(g, 2, 1)
    check("a wander inside the slop is still a click", a.moving is None)
    v.on_update(g, -(x + bw / 2) - 400, 900)
    v.on_end(g, 0, 0)
    check("the drag moved it, the desk is sound, and it stays selected",
          l.x == 0 and not d.faults() and a.moving and a.moving[0] is l,
          [o.rect() for o in d.outs])
    y0 = l.y
    check("an arrow then nudges it, no button held",
          key(w, Gdk.KEY_Down) and l.y > y0, (y0, l.y))
    g = Gesture()
    v.on_begin(g, 1, 1)
    check("a press on nothing is refused, and puts it down",
          g.denied and a.moving is None)
    v.on_click(None, 2, *gui.box(e, v.fr())[:2])
    check("a double-click selects the monitor under it",
          a.moving and a.moving[0] is e, a.moving)
    key(w, Gdk.KEY_Return)
    check("and Enter puts it down", a.moving is None)
    a.sel = 0
    check("a key reaches the App", key(w, Gdk.KEY_r) and e.transform == "90",
          e.transform)
    key(w, Gdk.KEY_p)
    yield
    check("a preview raises the keep dialog",
          w.alert and w.alert[0] == "keep", w.alert)
    check("while it is up, a key is the dialog's, not the desk's",
          not key(w, Gdk.KEY_r) and e.transform == "90", e.transform)
    w.alert[1].emit("response", "keep")
    yield
    check("Keep keeps it live", a.live_unsaved and not a.dialog
          and not w.alert, (a.live_unsaved, a.dialog))
    hw.rc[None] = 2
    key(w, Gdk.KEY_s)
    yield
    check("a failed save raises the error dialog, its reasons first",
          w.alert and w.alert[0] == "error"
          and w.alert[1].get_body().startswith("the REASON"),
          w.alert and w.alert[1].get_body())
    w.alert[1].emit("response", "close")
    yield
    check("Close closes it", not a.dialog and not w.alert)
    check("closing with changes unsaved asks", w.on_close(None)
          and w.alert and w.alert[0] == "quit")
    w.alert[1].emit("response", "discard")
    yield

def activate(g):
    d, outs, hw = desk()
    a = controller.App(d, hw)
    a.spawn = sync
    w = gui.Window(g, a)
    w.win.present()
    steps = drive(w, a, hw, d, outs)
    def tick():
        try:
            next(steps)
            return GLib.SOURCE_CONTINUE
        except StopIteration:
            return GLib.SOURCE_REMOVE
        except Exception as ex:
            fails.append("drive raised %r" % ex)
            g.quit()
            return GLib.SOURCE_REMOVE
    GLib.timeout_add(150, tick)
    g.hw, g.a = hw, a

g = Adw.Application(application_id="io.github.jello_d.hwdp.gdesk.test",
                    flags=Gio.ApplicationFlags.NON_UNIQUE)
g.connect("activate", activate)
g.run([])
check("Discard closes the window, and with it the program",
      g.a.done, g.a.dialog)
check("discarding a kept preview reverts it",
      ("--revert", []) in g.hw.calls, g.hw.calls)
print("FAILS:" + "|".join(fails) if fails else "OK")
PY
)
case $_out in *OK) ;; *) fail "window: $_out" ;; esac
pass "the window: drag, keys, keep and error dialogs, the quit prompt"

# --- the preview's cut: the real slicer, for the desk as edited ------------
if command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1
then
  _out=$(python3 -I - "$HERE" "$T" 2>&1 <<'PY'
import sys
exec(open(sys.argv[2] + "/common.py").read())
make_walls()
d, (e, p, l), hw = desk()
for o in d.outs:
    o.set_mm(600, 340) if o.w > o.h else o.set_mm(340, 600)
lay = "\n".join(model.slicer_layout(d, 600)) + "\n"
found, why = real.slice_preview({(0, 0): "aurora.png"}, lay,
                                sys.argv[2] + "/cache/p")
check("the cut gives a slice per panel of the cell",
      set(found) == {(0, 0, "eDP-1"), (0, 0, "DP-1"), (0, 0, "DP-2")},
      (found, why))
import cairo
sizes = {k[2]: (cairo.ImageSurface.create_from_png(v).get_width(),
                cairo.ImageSurface.create_from_png(v).get_height())
         for k, v in found.items()}
want = {x.split()[0]: (int(x.split()[7]), int(x.split()[8]))
        for x in lay.splitlines()}
check("each slice is its panel's size in the layout handed in",
      sizes == want, (sizes, want))
check("no wallpapers is nothing to cut",
      real.slice_preview({}, lay, sys.argv[2] + "/cache/p") == ({}, ""))
print("FAILS:" + "|".join(fails) if fails else "OK")
PY
)
  case $_out in *OK) ;; *) fail "preview cut: $_out" ;; esac
  pass "the preview: the desk as edited, cut small by the session's slicer"
else
  pass "the preview's cut not checked (no image tool here)"
fi

# --- the window: names, the grid, and every dialog they raise --------------
_out=$(env -i PATH=/usr/bin:/bin HOME="$T/home" XDG_RUNTIME_DIR="$T/run" \
  WAYLAND_DISPLAY="$_wl" GSK_RENDERER=cairo GDK_BACKEND=wayland \
  timeout 60 python3 -I - "$HERE" "$T" 2>&1 <<'PY'
import sys, time, cairo
exec(open(sys.argv[2] + "/common.py").read())
make_walls()
from gi.repository import Adw, Gdk, Gio, GLib

def drawn(label, fn, area, w, h):
    """Draw a tab into an image: an exception in the drawing fails."""
    try:
        cr = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h))
        fn(area, cr, w, h)
    except Exception as ex:
        fails.append("%s: drawing raised %r" % (label, ex))

def key(w, keyval):
    return w.on_key(None, keyval, 0, 0)

def surfaces_tab(w, a, hw):
    key(w, Gdk.KEY_2)
    check("2 is the surfaces tab", w.stack.get_visible_child_name()
          == "surfaces" and a.tab == 1, a.tab)
    key(w, Gdk.KEY_a)
    yield
    check("a opens the name form", w.alert and w.alert[0] == "name")
    d = w.alert[1]
    d.fields[0].set_text("mail!")
    d.ok.emit("clicked")
    yield
    check("a refused name keeps the form up, saying why",
          w.alert and w.alert[1] is d and "not !" in a.form["err"])
    d.fields[0].set_text("mail")
    d.fields[1].set_text("Mail")
    d.ok.emit("clicked")
    yield
    check("a good one closes it and joins the list",
          not w.alert and ["mail", "Mail"] in a.names
          and w.names.list.get_row_at_index(1) is not None, a.names)
    a.side = 1
    key(w, Gdk.KEY_e)
    yield
    check("e opens the form on the selected name, its name fixed",
          w.alert and w.alert[0] == "name"
          and not w.alert[1].fields[0].get_sensitive())
    w.alert[1].close()
    yield
    yield
    check("closing the form is the App's Esc: nothing left open",
          not w.alert and a.dialog is None and a.form is None,
          (a.dialog, a.form))

def virtual_tab(w, a, hw, outs):
    e, p, l = outs
    key(w, Gdk.KEY_3)
    g = w.grid
    g.area.set_size_request(900, 600)
    while g.area.get_width() == 0:
        yield
    W, H = g.area.get_width(), g.area.get_height()
    b = gui.vbox(gui.vframe(a, W, H), 1, 0, l)
    mid = (b[0] + b[2] / 2, b[1] + b[3] / 2)
    g.on_press(None, 1, *mid)
    check("a click selects that spot", a.vcell == [1, 0]
          and a.vspot() == (l, "full"), (a.vcell, a.vspot()))
    check("dropping a name on a spot places it there",
          g.on_drop(None, "comms", *mid) and
          [x.key() for x in a.surfaces] ==
          [model.Surface("comms", "DP-2", "full", 1, 0).key()], a.surfaces)
    key(w, Gdk.KEY_g)
    check("g cuts the panel, and what was whole goes to the top",
          a.surfaces[0].region == "top", a.surfaces[0].region)
    g.on_press(None, 1, b[0] + 5, b[1] + b[3] - 5)
    check("a click on the lower half selects the bottom",
          a.vspot() == (l, "bottom"), a.vspot())
    key(w, Gdk.KEY_Return)
    yield
    check("Enter opens the picker", w.alert and w.alert[0] == "pick")
    d = w.alert[1]
    d.search.set_text("mai")
    yield
    yield
    r = d.rows.get_row_at_index(0)
    check("typing filters the picker", r is not None and
          d.rows.get_row_at_index(1) is None and r.get_title() == "Mail")
    d.rows.emit("row-activated", r)
    yield
    check("choosing a row places it, and closes the picker",
          not w.alert and any(x.name == "mail" and x.region == "bottom"
                              for x in a.surfaces), a.surfaces)
    key(w, Gdk.KEY_g)
    key(w, Gdk.KEY_g)
    yield
    check("joining two placed halves asks first",
          w.alert and w.alert[0] == "unsplit")
    w.alert[1].emit("response", "join")
    yield
    check("Join unplaces both", not w.alert and not a.surfaces, a.surfaces)
    key(w, Gdk.KEY_b)
    yield
    check("b opens the wallpaper picker, the default first",
          w.alert and w.alert[0] == "wpick" and
          w.alert[1].rows.get_row_at_index(0).get_title() == "(default)")
    d = w.alert[1]
    pic = d.rows.get_row_at_index(1).picture
    for _ in range(60):
        if pic.get_paintable() is not None:
            break
        yield
    check("an image's row shows its thumbnail",
          pic.get_paintable() is not None)
    d.rows.emit("row-activated", d.rows.get_row_at_index(2))
    yield
    check("choosing an image sets the cell's wallpaper",
          a.walls == {(1, 0): "night sky.png"}, a.walls)
    if CUTTER:
        for _ in range(100):
            if g.slices.cut:
                break
            yield
        check("the cell's wallpaper is cut across its panels to show it",
              set(g.slices.cut) == {(1, 0, "eDP-1"), (1, 0, "DP-1"),
                                    (1, 0, "DP-2")},
              (sorted(g.slices.cut), g.slices.why))
    key(w, Gdk.KEY_plus)
    check("+ adds a column", a.grid == (4, 3), a.grid)
    g.on_drop(None, "comms", *mid)
    drawn("virtual", g._draw, g.area, 900, 600)
    drawn("physical", w.view._draw, w.view.area, 900, 600)

def delete_and_save(w, a, hw):
    key(w, Gdk.KEY_2)
    a.side = 1
    key(w, Gdk.KEY_D)
    yield
    check("D asks before a name goes", w.alert and w.alert[0] == "delname"
          and "mail" in w.alert[1].get_heading())
    w.alert[1].emit("response", "delete")
    yield
    check("Delete takes it from the list", a.names == [["comms", "Comms"]],
          a.names)
    key(w, Gdk.KEY_s)
    yield
    said = [c[0] for c in hw.calls]
    check("a save writes the desk and the wallpapers",
          "desk" in said and "walls" in said, said)
    check("a saved window closes without asking", not w.on_close(None))
    yield

def drive(w, a, hw, outs):
    for step in (surfaces_tab(w, a, hw), virtual_tab(w, a, hw, outs),
                 delete_and_save(w, a, hw)):
        yield from step

def activate(g):
    d, outs, hw = desk()
    a = controller.App(d, hw)
    a.spawn = sync
    w = gui.Window(g, a)
    w.win.present()
    steps = drive(w, a, hw, outs)
    def tick():
        try:
            next(steps)
            return GLib.SOURCE_CONTINUE
        except StopIteration:
            g.quit()
            return GLib.SOURCE_REMOVE
        except Exception as ex:
            fails.append("drive raised %r" % ex)
            g.quit()
            return GLib.SOURCE_REMOVE
    GLib.timeout_add(150, tick)

g = Adw.Application(application_id="io.github.jello_d.hwdp.gdesk.test2",
                    flags=Gio.ApplicationFlags.NON_UNIQUE)
g.connect("activate", activate)
g.run([])
print("FAILS:" + "|".join(fails) if fails else "OK")
PY
)
case $_out in *OK) ;; *) fail "window, names and grid: $_out" ;; esac
pass "the window: names added and deleted, a grid placed by click, drop and"\
" picker, cut and joined, a wallpaper, saved"
