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
    defaultsv = {}
    def default_wallpapers(self):
        return dict(self.defaultsv)
    def wallpaper_images(self):
        try:                    # as the real one: no directory, no images
            return sorted(os.listdir(WALLS), key=str.lower)
        except OSError:
            return []
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

def make_many(n=40):
    """N full-size JPEGs after those (zz-*), a picker's worth, to see
    every row get its picture."""
    import gi
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf
    pb = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, False, 8, 1920, 1200)
    for i in range(n):
        pb.fill(0x204060ff + (i << 24))
        pb.savev(os.path.join(WALLS, "zz-%02d.jpg" % i), "jpeg", [], [])
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

# The cache: names stable for the same input, new for a changed one, and
# pruning keeps the newest of its own names and nothing else.
os.environ["XDG_CACHE_HOME"] = sys.argv[2] + "/cache-pure"
check("one layout, one directory; another layout, another",
      gui.layout_dir("a\n") == gui.layout_dir("a\n")
      != gui.layout_dir("b\n"), gui.layout_dir("a\n"))
img = sys.argv[2] + "/thumb-src.png"
open(img, "wb").write(b"x")
t1 = gui.thumb_file(img)
os.utime(img, (1, 1))
check("an edited image gets a new thumbnail name",
      gui.thumb_file(img) != t1)
base = os.path.join(gui.cache_root(), "slices")
os.makedirs(base + "/not-ours")
for i in range(5):
    d = os.path.join(base, "%016x" % i)
    os.makedirs(d)
    os.utime(d, (1000 + i, 1000 + i))
gui.prune("slices", 2, r"[0-9a-f]{16}")
check("pruning keeps the newest, and leaves names it did not write",
      sorted(os.listdir(base)) == ["%016x" % 3, "%016x" % 4, "not-ours"],
      sorted(os.listdir(base)))
os.environ["XDG_CACHE_HOME"] = sys.argv[2] + "/cache"

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

# --- the app_id: the key an integrator's window rule matches on -----------
_id=$(env -i PATH=/usr/bin:/bin sh "$HERE/bin/hwdp" gdesk --app-id) \
  || fail "hwdp gdesk --app-id failed with no session"
[ "$_id" = io.github.jello_d.hwdp.gdesk ] \
  || fail "the app_id changed (a published contract): $_id"
env -i PATH=/usr/bin:/bin sh "$HERE/bin/hwdp" gdesk --app-id x \
  >/dev/null 2>&1 && fail "--app-id took an argument"
pass "hwdp gdesk --app-id prints the window's app_id, with no session"

# --- one desk tool at a time, of either kind ---------------------------------
mkdir -p "$T/lockrun"
_out=$(env -i PATH=/usr/bin:/bin HOME="$T/home" XDG_RUNTIME_DIR="$T/lockrun" \
  python3 -I - "$HERE" "$T" 2>&1 <<'PY'
import os, subprocess, sys, time
exec(open(sys.argv[2] + "/common.py").read())
env = dict(os.environ, WAYLAND_DISPLAY="wayland-nowhere")
def tool(cmd):
    p = subprocess.run(["sh", here + "/bin/hwdp", cmd], env=env,
                       stdin=subprocess.DEVNULL, capture_output=True,
                       text=True, timeout=30)
    return p.returncode, p.stderr
fd, why = hwdp.desk_lock("the test")
check("the first takes the lock", fd is not None, why)
for cmd in ("gdesk", "desk"):
    rc, err = tool(cmd)
    check("with one open, hwdp %s refuses, exit 5, saying which" % cmd,
          rc == 5 and "already open (the test, pid %d)" % os.getpid()
          in err, (rc, err))
kid = subprocess.Popen(["sleep", "3"])        # started while it is held
os.close(fd)
fd, why = hwdp.desk_lock("again")
check("let go, it is free, though a child it started still runs",
      fd is not None and kid.poll() is None, why)
os.close(fd)
kid.kill()
rc, err = tool("desk")
check("free, a tool gets past it (to the terminal it needs)",
      rc == 2 and "needs a terminal" in err, (rc, err))
print("FAILS:" + "|".join(fails) if fails else "OK")
PY
)
case $_out in *OK) ;; *) fail "lock: $_out" ;; esac
pass "one desk tool at a time: the second refuses (exit 5), naming the first"

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
# A SHARED copy (/opt/hwdp) has no bin/wallpaper-slicer: the slicer is
# user-only, so it is found on PATH there.
shared = hwdp.Hwdp()
shared.libexec = sys.argv[2] + "/opt/libexec"
shared.lib = real.lib
os.makedirs(shared.libexec, exist_ok=True)
os.environ["PATH"] = here + "/bin:" + os.environ["PATH"]
found, why = shared.slice_preview({(0, 0): "aurora.png"}, lay,
                                  sys.argv[2] + "/cache/q")
check("a shared copy with no slicer beside it finds the one on PATH",
      len(found) == 3, (found, why))
os.environ["PATH"] = "/usr/bin:/bin"
check("with none anywhere it says so, not an errno",
      shared.slice_preview({(0, 0): "aurora.png"}, lay,
                           sys.argv[2] + "/cache/q")
      == ({}, "wallpaper-slicer is not installed"))
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
make_many()
from gi.repository import Adw, Gdk, Gio, GLib, Gtk

def drawn(label, fn, area, w, h):
    """Draw a tab into an image: an exception in the drawing fails."""
    try:
        cr = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h))
        fn(area, cr, w, h)
    except Exception as ex:
        fails.append("%s: drawing raised %r" % (label, ex))

def key(w, keyval):
    return w.on_key(None, keyval, 0, 0)

def faint_and_lit():
    """One panel cut top-bottom over black, a WHITE slice: comms placed on
    the top half (no tint over a picture, so grey), the bottom selected
    (stronger). Read back away from the label and the outline."""
    d, (e, p, l), hw = desk()
    a = controller.App(d, hw)
    a.splits[("DP-2", 0, 0)] = "top-bottom"
    a.surfaces = [model.Surface("comms", "DP-2", "top", 0, 0)]
    img = cairo.ImageSurface(cairo.FORMAT_RGB24, 50, 50)
    c = cairo.Context(img)
    c.set_source_rgb(1, 1, 1)
    c.paint()
    out = cairo.ImageSurface(cairo.FORMAT_ARGB32, 200, 100)
    cr = cairo.Context(out)
    cr.set_source_rgb(0, 0, 0)
    cr.paint()
    fg, accent = Gdk.RGBA(), Gdk.RGBA()
    fg.parse("white")
    accent.parse("#9141ac")
    gui.draw_panel(cr, a, l, 0, 0, (0, 0, 200, 100), "bottom", fg, accent,
                   img)
    out.flush()
    px = out.get_data()

    def rgb(x, y):
        i = y * out.get_stride() + x * 4
        return px[i + 2], px[i + 1], px[i]          # BGRA in memory
    top, bottom = rgb(12, 12), rgb(12, 88)
    check("over a picture a placed surface has no tint: grey, about half",
          top[0] == top[1] == top[2] and abs(top[0] - 128) <= 3, top)
    check("and the selected spot shows it whole",
          bottom[0] == bottom[1] == bottom[2]
          and abs(bottom[0] - 255) <= 3, bottom)

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
    pics = []
    i = 1
    while d.rows.get_row_at_index(i) is not None:
        pics.append(d.rows.get_row_at_index(i).picture)
        i += 1
    for _ in range(150):
        if all(x.get_paintable() is not None for x in pics):
            break
        yield
    bad = [x.get_tooltip_text() for x in pics
           if x.get_paintable() is None or x.get_tooltip_text()]
    check("EVERY row of a full picker gets its picture (%d)" % len(pics),
          len(pics) == 42 and not bad, (len(pics), bad[:3]))
    imgs = [os.path.join(WALLS, x) for x in hw.wallpaper_images()]
    check("every thumbnail is kept in the cache",
          all(os.path.exists(gui.thumb_file(x)) for x in imgs),
          [x for x in imgs if not os.path.exists(gui.thumb_file(x))][:3])
    fresh = gui.Thumbs()
    fresh._decode = lambda path: (None, "decoded, not read from the cache")
    seen = Gtk.Picture()
    fresh.into(imgs[0], seen)
    for _ in range(40):
        if seen.get_paintable() is not None:
            break
        yield
    check("a later window shows it from the cache, decoding nothing",
          seen.get_paintable() is not None and not seen.get_tooltip_text(),
          seen.get_tooltip_text())
    if CUTTER:
        d.rows.select_row(d.rows.get_row_at_index(2))
        for _ in range(100):
            if d.preview.cut:
                break
            yield
        check("the picker shows the highlighted image cut across the desk",
              set(d.preview.cut) == {(1, 0, "eDP-1"), (1, 0, "DP-1"),
                                     (1, 0, "DP-2")} and not a.walls,
              (sorted(d.preview.cut), d.preview.why, a.walls))
    d.rows.emit("row-activated", d.rows.get_row_at_index(2))
    yield
    check("choosing an image sets the cell's wallpaper",
          a.walls == {(1, 0): "night sky.png"}, a.walls)
    if CUTTER:
        want = {(c, r, o) for c, r in ((1, 0), (2, 1))
                for o in ("eDP-1", "DP-1", "DP-2")}
        for _ in range(100):
            if want <= set(g.slices.cut):
                break
            yield
        check("the cell's wallpaper is cut across its panels to show it,"
              " and the default's cell too", set(g.slices.cut) == want,
              (sorted(g.slices.cut), g.slices.why))
        here = gui.layout_dir("\n".join(
            model.slicer_layout(a.desk, gui.PREVIEW_SPAN)) + "\n")
        check("the cut is kept under this layout's own directory",
              os.path.isdir(here) and any(x.startswith("img-")
                                          for x in os.listdir(here)), here)
    check("the preview cuts the integrator's default where the desk sets"
          " none", g.shown_walls().get((2, 1)) == "aurora.png"
          and (1, 0) in g.shown_walls(), g.shown_walls())
    key(w, Gdk.KEY_plus)
    check("+ adds a column", a.grid == (4, 3), a.grid)
    g.on_drop(None, "comms", *mid)
    drawn("virtual", g._draw, g.area, 900, 600)
    drawn("physical", w.view._draw, w.view.area, 900, 600)

class G:
    denied = False
    def set_state(self, st):
        self.denied = True

def arrange_tab(w, a, hw):
    key(w, Gdk.KEY_3)
    g = w.grid
    key(w, Gdk.KEY_A)
    yield
    check("A opens an arrangement, its own buttons in place of the grid's",
          a.arr is not None and w.groups["arrange"].get_visible()
          and not w.groups["virtual"].get_visible())
    W, H = g.area.get_width(), g.area.get_height()
    (x0, y0), dims = gui.arr_dims(a)
    vf = gui.vframe(a, W, H, dims)
    def mid(pos):
        r = gui.cell_rect(vf, pos[0] - x0, pos[1] - y0)
        return r[0] + r[2] / 2, r[1] + r[3] / 2
    drawn("arrangement", g._draw, g.area, W, H)
    gest = G()
    sx, sy = mid((0, 0))
    g.on_tile_begin(gest, sx, sy)
    tx, ty = mid((0, -1))
    g.on_tile_update(gest, tx - sx, ty - sy)
    check("a drag outlines where the tile will land",
          not gest.denied and g.hover == (0, -1), g.hover)
    g.on_tile_end(gest, tx - sx, ty - sy)
    check("and drops it there, into the ring above the grid",
          a.arr["at"].get((0, -1)) == (0, 0) and (0, 0) not in a.arr["at"],
          sorted(a.arr["at"].items()))
    full = [p for p, c in a.arr["at"].items() if a.tile_holds(c)[0]]
    a.arr["sel"] = full[0]
    key(w, Gdk.KEY_d)
    yield
    check("deleting a tile that holds something asks",
          w.alert and w.alert[0] == "deltile")
    w.alert[1].emit("response", "cancel")
    yield
    check("Keep it keeps it", not w.alert and full[0] in a.arr["at"])
    rows = len({p[1] for p in a.arr["at"]})
    cols = len({p[0] for p in a.arr["at"]})
    key(w, Gdk.KEY_Return)
    yield
    check("Enter commits it, evened out into a grid",
          a.arr is None and a.grid == (cols, rows)
          and w.groups["virtual"].get_visible(), (a.grid, cols, rows))

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
    faint_and_lit()
    for step in (surfaces_tab(w, a, hw), virtual_tab(w, a, hw, outs),
                 arrange_tab(w, a, hw), delete_and_save(w, a, hw)):
        yield from step

def activate(g):
    d, outs, hw = desk()
    hw.defaultsv = {(2, 1): "aurora.png"}
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

# --- the REAL tool's window carries that app_id, read from the compositor --
# The whole path a person takes (bin/hwdp, cmd/gdesk, desk-gtk) against the
# headless sway's own output, sandboxed; killed before it can save anything.
# TWICE: with no session bus, and with one of its own. GTK takes the
# application's id only once it has registered on the bus, and the program's
# name otherwise, which was `desk-gtk`: a rule keyed on the contract would
# have stopped matching wherever the bus was missing.
# It sets _seen rather than printing it: called as $(...), its subshell
# would run the harness's exit trap on the way out and remove $T.
_app_id_seen() {   # [wrapper...]: _seen = the app_id of the first window
  ( exec "$@" env -i PATH=/usr/bin:/bin HOME="$T/home" \
      XDG_RUNTIME_DIR="$T/run" XDG_CONFIG_HOME="$T/home/.config" \
      XDG_STATE_HOME="$T/home/.state" XDG_CACHE_HOME="$T/home/.cache" \
      KANSHI_PROFILES="$T/no-profiles" HWDP_HOOK_ROOT="$T/no-hooks" \
      HWDP_MACHINE_HOOKS="$T/no-hooks" HWDP_MACHINE_PROVIDERS="$T/no-machine" \
      HWDP_PROVIDER_ROOT="$T/no-user" WAYLAND_DISPLAY="$_wl" \
      GSK_RENDERER=cairo GDK_BACKEND=wayland \
      DBUS_SESSION_BUS_ADDRESS="${_bus:-disabled:}" \
      sh "$HERE/bin/hwdp" gdesk >"$T/gdesk.log" 2>&1 ) &
  _gd=$!
  harness_cleanup "kill $_gd $_sway 2>/dev/null"
  _i=0 _seen=
  while [ "$_i" -lt 75 ]; do
    _seen=$(swaymsg -s "$T/run/sway.sock" -t get_tree 2>/dev/null \
      | python3 -c '
import json, sys
def walk(n):
    if n.get("app_id"):
        print(n["app_id"])
    for c in n.get("nodes", []) + n.get("floating_nodes", []):
        walk(c)
walk(json.load(sys.stdin))' 2>/dev/null) || _seen=
    [ -n "$_seen" ] && break
    _i=$((_i + 1))
    sleep 0.2
  done
  kill "$_gd" 2>/dev/null || :
  _j=0
  while kill -0 "$_gd" 2>/dev/null && [ "$_j" -lt 25 ]; do
    _j=$((_j + 1)); sleep 0.2
  done
}
_bus=
_app_id_seen
[ "$_seen" = "$_id" ] || fail "with no session bus the window's app_id is \
'$_seen', not the published '$_id': $(tail -3 "$T/gdesk.log")"
if command -v dbus-run-session >/dev/null 2>&1; then
  _app_id_seen dbus-run-session --
  [ "$_seen" = "$_id" ] || fail "with a session bus the window's app_id is \
'$_seen', not the published '$_id': $(tail -3 "$T/gdesk.log")"
  pass "the real hwdp gdesk window carries the published app_id, bus or none"
else
  pass "the real window carries the published app_id with no bus (no"\
" dbus-run-session here to try one)"
fi
