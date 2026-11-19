"""hwdp desk: every call out to hwdp, and the offline stand-in for it."""
import os
import re
import subprocess
import threading

from .model import IMAGE_SUFFIXES, Output, REGION_OF, Surface


def here():
    """The package's own dirs, from the dispatcher's environment or our own
    path (a checkout run directly: this file is lib/hwdp_desk/hwdp.py)."""
    root = os.path.realpath(__file__)
    for _ in range(3):
        root = os.path.dirname(root)
    return (os.environ.get("HWDP_LIBEXEC", os.path.join(root, "libexec")),
            os.environ.get("HWDP_LIB", os.path.join(root, "lib")))


# --- talking to hwdp ---------------------------------------------------------

class Hwdp:
    """Every call out of this tool, in one place, so a test replaces it."""

    def __init__(self):
        self.libexec, self.lib = here()
        self.overlay = None

    def _run(self, *argv, stdin=None):
        # The package's dirs go to every child explicitly: displayset_lib
        # refuses to load without HWDP_LIB, and only the dispatcher exports
        # it, so a tool started any other way could not re-pack at all.
        env = dict(os.environ, HWDP_LIB=self.lib, HWDP_LIBEXEC=self.libexec)
        p = subprocess.run(argv, input=stdin, capture_output=True,
                           text=True, env=env)
        return p.returncode, p.stdout, p.stderr

    def geometry(self):
        rc, out, err = self._run(os.path.join(self.libexec, "cmd",
                                              "geometry"), "--now")
        if rc != 0 or not out.strip():
            raise SystemExit("hwdp desk: no outputs to arrange (it needs"
                             " a session)\n" + err)
        outs = []
        for line in out.splitlines():
            f = line.split()
            o = Output(f[0], f[3], int(f[5]), int(f[6]), int(f[7]),
                       int(f[8]))
            if len(f) >= 12 and f[10].isdigit() and f[11].isdigit():
                o.set_mm(int(f[10]), int(f[11]))
            outs.append(o)
        return outs

    def repack(self, old, new):
        lines = ["old\t%s\t%d\t%d\t%d\t%d" % ((n,) + r)
                 for n, r in old.items()]
        lines += ["new\t%s\t%d\t%d" % ((n,) + s) for n, s in new.items()]
        rc, out, err = self._run(
            "sh", "-c", '. "$1/displayset_lib"; layout_repack', "_",
            self.lib, stdin="\n".join(lines) + "\n")
        # LOUD: an empty answer here once meant "nothing moves", which left
        # a rotated monitor overlapping its neighbour with no word said.
        if rc != 0 or not out.strip():
            raise RuntimeError("hwdp arrange: layout_repack failed (%d): %s"
                               % (rc, err.strip()))
        pos = {}
        for line in out.splitlines():
            n, x, y = line.split("\t")
            pos[n] = (int(x), int(y))
        return pos

    def arrange(self, mode, placements, progress=None):
        """PROGRESS, when given, is called with each line arrange says as
        it says it, so a save that waits on a slow hook is not silent."""
        argv = [os.path.join(self.libexec, "cmd", "arrange")]
        if mode:
            argv.append(mode)
        env = dict(os.environ, HWDP_LIB=self.lib, HWDP_LIBEXEC=self.libexec)
        p = subprocess.Popen(argv + list(placements), stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.PIPE, text=True, env=env)
        said = []

        def read():
            for line in p.stderr:
                line = line.strip()
                if line:
                    said.append(line)
                    if progress:
                        progress(line)
        # Done when ARRANGE exits, not when its stderr closes: a hook that
        # leaves something running holding that pipe must not hold us.
        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        rc = p.wait()
        reader.join(0.5)
        # All of it on a failure (the reason comes before the summary); the
        # last line on success, which is what the status line shows.
        return rc, "\n".join(said) if rc else (said[-1] if said else "")

    def _surf(self, *args, stdin=None):
        rc, out, err = self._run(os.path.join(self.libexec, "cmd",
                                              "surfaces"), *args, stdin=stdin)
        return rc, out, err.strip() or "exit %d" % rc

    def surfaces(self, desk):
        """(placements, default, why) for this desk, as the tool edits them;
        (None, None, why) when the files cannot be read safely. Read through
        `hwdp surfaces --map`, the published answer, never by parsing a
        file: the region comes back as fractions, the default as `* *`."""
        rc, out, why = self._surf("--map")
        if rc != 0:
            return None, None, why
        found, default = [], None
        for line in out.splitlines():
            f = line.split()
            region = REGION_OF.get(tuple(float(v) for v in f[9:13]), "full")
            if f[2] == "*":
                default = Surface(f[0], f[1], region, None, None)
            else:
                found.append(Surface(f[0], f[1], region, int(f[2]),
                                     int(f[3])))
        return found, default, ""

    def splits(self):
        """[(connector, cx, cy, split)] for the panels on now."""
        rc, out, _ = self._surf("--splits")
        return [(f[0], int(f[1]), int(f[2]), f[3]) for f in
                (ln.split() for ln in out.splitlines()) if len(f) == 4] \
            if rc == 0 else []

    def grid(self):
        """(w, h) the desk sets, or None."""
        rc, out, _ = self._surf("--grid")
        f = out.split()
        return (int(f[0]), int(f[1])) if rc == 0 and len(f) == 2 else None

    def wallpapers(self):
        """{(cx, cy): file}, this desk's wallpapers inside its grid; empty
        when it sets none (every cell keeps its default)."""
        rc, out, _ = self._surf("--wallpapers")
        found = {}
        for ln in out.splitlines() if rc == 0 else []:
            f = ln.split(None, 2)
            if len(f) == 3 and f[0].isdigit() and f[1].isdigit():
                found[(int(f[0]), int(f[1]))] = f[2]
        return found

    def wallpaper_dir(self):
        """Where the images are: HWDP_WALLPAPER_DIR, else
        ~/Pictures/wallpaper, which is where the integrator points the
        plugin."""
        return os.environ.get("HWDP_WALLPAPER_DIR") or os.path.expanduser(
            "~/Pictures/wallpaper")

    def wallpaper_images(self):
        """The images a workspace can take: the files in the wallpaper
        directory, by name."""
        d = self.wallpaper_dir()
        try:
            names = os.listdir(d)
        except OSError:
            return []
        return sorted((n for n in names if not n.startswith(".")
                       and n.lower().endswith(IMAGE_SUFFIXES)
                       and os.path.isfile(os.path.join(d, n))),
                      key=str.lower)

    def slice_preview(self, walls, layout, outdir):
        """WALLS ({(cx, cy): file}) cut for LAYOUT (`hwdp geometry` lines,
        see model.slicer_layout) by wallpaper-slicer into OUTDIR, never the
        session's own cache: {(cx, cy, output): slice path}, and why not
        when the cut failed."""
        if not walls:
            return {}, ""
        os.makedirs(outdir, exist_ok=True)
        cut = os.path.join(outdir, "desk.map")
        with open(cut, "w") as fh:
            fh.writelines("%d %d %s\n" % (x, y, f)
                          for (x, y), f in sorted(walls.items()))
        slicer = os.path.join(os.path.dirname(self.libexec), "bin",
                              "wallpaper-slicer")
        env = dict(os.environ, HWDP_LIB=self.lib,
                   WALLPAPER_SLICER_LAYOUT=layout)
        try:
            p = subprocess.run([slicer, "-M", cut, "-d",
                                self.wallpaper_dir(), "-o", outdir],
                               capture_output=True, text=True, env=env,
                               timeout=120, stdin=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError) as e:
            return {}, str(e)
        man = p.stdout.strip().splitlines()
        if p.returncode != 0 or not man or not os.path.isfile(man[-1]):
            return {}, p.stderr.strip() or "exit %d" % p.returncode
        found = {}
        with open(man[-1]) as fh:
            for ln in fh:
                f = ln.split(None, 3)
                if len(f) == 4 and f[3].startswith("/") and \
                        f[0].isdigit() and f[1].isdigit():
                    found[(int(f[0]), int(f[1]), f[2])] = f[3].rstrip("\n")
        # A cell the slicer could not cut is its plain line, not an error,
        # so say which, rather than hand back less in silence.
        uncut = sorted(f for (x, y), f in walls.items()
                       if not any(k[:2] == (x, y) for k in found))
        return found, ("not cut: " + ", ".join(uncut) +
                       (" (%s)" % p.stderr.strip() if p.stderr.strip()
                        else "")) if uncut else ""

    def write_wallpapers(self, walls):
        rc, _, why = self._surf("--write-wallpapers", stdin="".join(
            "%d %d %s\n" % (x, y, f) for (x, y), f in sorted(walls.items())))
        return rc, why

    def names(self):
        """[[name, label], ...], the global list, in its order."""
        rc, out, _ = self._surf("--names")    # always `name label`
        return [ln.split(None, 1) for ln in out.splitlines()
                if len(ln.split(None, 1)) == 2] if rc == 0 else []

    def write_desk(self, grid, surfaces, default, splits=()):
        lines = "grid %d %d\n" % grid
        lines += "".join("split %s cell %d %d %s\n" % k for k in splits)
        lines += "".join("surface %s %s cell %d %d %s\n"
                         % (s.name, s.conn, s.cx, s.cy, s.region)
                         for s in surfaces)
        if default:
            lines += "default %s %s %s\n" % (default.name, default.conn,
                                             default.region)
        rc, _, why = self._surf("--write", stdin=lines)
        return rc, why

    def write_names(self, names):
        rc, _, why = self._surf("--write-names", stdin="".join(
            "%s %s\n" % (n, lab) for n, lab in names))
        return rc, why

    def apply(self):
        """Fire `changed` (`hwdp apply`), so what was saved reaches THIS
        session: a desk file changes the grid and the workspace names with
        no display event, and nothing else would tell the integrator's hooks
        (a 4x3 save stayed 3x3 on screen, 2026-11-18)."""
        rc, _, err = self._run(os.path.join(self.libexec, "cmd", "apply"),
                               "-q")
        return rc, err.strip()

    def identify(self, on):
        if on and self.overlay is None:
            self.overlay = subprocess.Popen(
                [os.path.join(self.libexec, "cmd", "identify"),
                 "--parent", str(os.getpid())],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
        elif not on and self.overlay is not None:
            self.overlay.terminate()
            try:
                self.overlay.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.overlay.kill()
            self.overlay = None
        return self.overlay is not None


def panel_label(name):
    """A stored panel name (EDID "Make Model Serial", or @builtin) as a
    person reads it: the model number, or `laptop`."""
    if name == "@builtin":
        return "laptop"
    w = name.split()
    return w[-2] if len(w) >= 2 else (w[0] if w else name)


def parse_profile(text, native):
    """The panels of a kanshi profile hwdp wrote: [(name, transform, x, y,
    w, h, on, (mode_w, mode_h, rate))], w and h the LAID-OUT size. From the
    `# hwdp-rect` comment where there is one; else the mode, turned by the
    transform; the built-in, which carries no mode, at NATIVE (w, h)."""
    rect, outs = {}, []
    for line in text.splitlines():
        m = re.match(r'# hwdp-rect "([^"]+)" (-?\d+) (-?\d+) (\d+) (\d+)',
                     line)
        if m:
            rect[m.group(1)] = tuple(int(v) for v in m.group(2, 3, 4, 5))
            continue
        m = re.match(r'\s*output "([^"]+)"(.*)$', line)
        if not m:
            continue
        name, rest = m.group(1), m.group(2)
        mode = re.search(r" mode (\d+)x(\d+)(?:@([\d.]+)Hz)?", rest)
        tr = re.search(r" transform (\S+)", rest)
        pos = re.search(r" position (-?\d+),(-?\d+)", rest)
        transform = tr.group(1) if tr else "normal"
        mw, mh = (int(mode.group(1)), int(mode.group(2))) if mode \
            else (native or (0, 0))
        rate = float(mode.group(3)) if mode and mode.group(3) else 0.0
        if name in rect:
            w, h = rect[name][2], rect[name][3]
        elif transform.replace("flipped-", "") in ("90", "270"):
            w, h = mh, mw
        else:
            w, h = mw, mh
        x, y = (int(pos.group(1)), int(pos.group(2))) if pos else (0, 0)
        outs.append((name, transform, x, y, w, h,
                     not rest.strip().endswith("disable"), (mw, mh, rate)))
    return outs


def distinct_labels(outs):
    """Where two panels would read the same (three of one model), each
    takes the start of its serial too: a label that names two panels
    cannot say which one is selected."""
    seen = {}
    for o in outs:
        seen.setdefault(o.label, []).append(o)
    for same in seen.values():
        if len(same) > 1:
            for o in same:
                w = o.conn.split()
                if len(w) >= 2 and o.conn != "@builtin":
                    o.label = "%s/%s" % (o.label, w[-1][:4])
    return outs


class OfflineHwdp(Hwdp):
    """A desk AWAY from its panels: read from its files and written back to
    them, never applied. Surfaces go through `hwdp surfaces` with
    HWDP_DESK set, the layout through `hwdp profile --write`."""
    offline = True

    def apply(self):
        return 0, ""                           # never applied: not here

    def __init__(self, key, name):
        super().__init__()
        self.key, self.name = key, name
        os.environ["HWDP_DESK"] = key          # every `hwdp surfaces` call
        self.desk = None                       # set once the App has one
        self.modes = {}
        self.has_profile = False

    def _native_builtin(self):
        rc, out, _ = self._run(os.path.join(self.libexec, "cmd", "panels"))
        for line in out.splitlines():
            f = line.split()
            if len(f) == 3 and f[0].startswith(("eDP", "LVDS", "DSI")):
                return int(f[1]), int(f[2])
        return None

    def geometry(self):
        prof = os.path.join(os.environ.get("KANSHI_PROFILES") or os.path.join(
            os.environ.get("XDG_CONFIG_HOME") or
            os.path.expanduser("~/.config"), "kanshi", "profiles"),
            self.key + ".conf")
        native = self._native_builtin()
        outs = []
        if os.path.exists(prof):
            self.has_profile = True
            with open(prof) as fh:
                for (name, tr, x, y, w, h, on, mode) in \
                        parse_profile(fh.read(), native):
                    o = Output(name, tr, x, y, w, h)
                    o.on, o.label = on, panel_label(name)
                    self.modes[name] = mode
                    outs.append(o)
            return distinct_labels(outs)
        # No layout recorded (a generic desk, or one never arranged): the
        # panels its surfaces name, side by side; only the laptop's size is
        # known. Its layout cannot be saved from here (see arrange).
        rc, out, _ = self._surf("--raw")
        x = 0
        for line in out.splitlines():
            f = line.split("\t")
            if len(f) < 3 or any(o.conn == f[2] for o in outs):
                continue
            w, h = native if f[2] == "@builtin" and native else (1920, 1080)
            o = Output(f[2], "normal", x, 0, w, h)
            o.label = panel_label(f[2])
            outs.append(o)
            x += w
        if not outs and native:
            o = Output("@builtin", "normal", 0, 0, *native)
            o.label = "laptop"
            outs.append(o)
        return distinct_labels(outs)

    def surfaces(self, desk):
        rc, out, why = self._surf("--raw")
        if rc != 0:
            return None, None, why
        found, default = [], None
        for line in out.splitlines():
            f = line.split("\t")
            if len(f) != 6:
                continue
            if f[0] == "default":
                default = Surface(f[1], f[2], f[5], None, None)
            elif f[0] == "surface":
                found.append(Surface(f[1], f[2], f[5], int(f[3]), int(f[4])))
        return found, default, ""

    def splits(self):
        rc, out, _ = self._surf("--raw")
        return [(f[2], int(f[3]), int(f[4]), f[5]) for f in
                (ln.split("\t") for ln in out.splitlines())
                if len(f) == 6 and f[0] == "split"] if rc == 0 else []

    def write_desk(self, grid, surfaces, default, splits=()):
        lines = "grid %d %d\n" % grid
        lines += "".join('split "%s" cell %d %d %s\n' % k for k in splits)
        lines += "".join('surface %s "%s" cell %d %d %s\n'
                         % (s.name, s.conn, s.cx, s.cy, s.region)
                         for s in surfaces)
        if default:
            lines += 'default %s "%s" %s\n' % (default.name, default.conn,
                                              default.region)
        rc, _, why = self._surf("--write", stdin=lines)
        return rc, why

    def arrange(self, mode, placements, progress=None):
        if mode:
            return 2, "%s is not attached: a preview needs its panels" \
                % self.name
        if not self.has_profile:
            return 2, ("%s has no layout recorded: arrange it at the desk"
                       " first" % self.name)
        recs = []
        for o in self.desk.outs:
            if not o.on:
                recs.append("off\t%s" % o.conn)
                continue
            mw, mh, rate = self.modes.get(o.conn, (0, 0, 0.0))
            recs.append("on\t%s\t%d\t%d\t%.3f\t%s\t%d\t%d\t%d\t%d" % (
                o.conn, mw, mh, rate, o.transform, o.x, o.y, o.w, o.h))
        rc, out, err = self._run(os.path.join(self.libexec, "cmd", "profile"),
                                 "--write", self.key,
                                 stdin="\n".join(recs) + "\n")
        return rc, err.strip()

    def identify(self, on):
        return False
