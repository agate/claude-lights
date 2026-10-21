"""Generate the isometric line-art illustrations for the Claude Lights site into site/art/.

Same drawing rules as honghao.me (scripts/gen_icons.py in agate/agate.github.io):
30-degree isometric, 1px ink lines, three face tones, one meaningful accent.

Run: python3 scripts/gen_site_art.py
"""
import math, pathlib

C30, S30 = math.cos(math.pi / 6), 0.5
INK, GROUND, TOP, LEFT, RIGHT = "#171717", "#fafafa", "#ffffff", "#f1f1f1", "#e6e6e6"


class Iso:
    def __init__(self, s, ox, oy):
        self.s, self.ox, self.oy, self.out, self.seen = s, ox, oy, [], []

    def p(self, x, y, z):
        q = (self.ox + (x - y) * C30 * self.s, self.oy + (x + y) * S30 * self.s - z * self.s)
        self.seen.append(q)
        return q

    def poly(self, pts, fill=GROUND, stroke=INK, sw=1, extra=""):
        d = " ".join(f"{a:.1f},{b:.1f}" for a, b in (self.p(*q) for q in pts))
        self.out.append(f'<polygon points="{d}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" {extra}/>')

    def line(self, a, b, stroke=INK, sw=1, extra=""):
        (x1, y1), (x2, y2) = self.p(*a), self.p(*b)
        self.out.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{stroke}" stroke-width="{sw}" {extra}/>')

    def box(self, x, y, z, w, d, h, top=TOP, left=LEFT, right=RIGHT, extra=""):
        # visible faces: +y face (lower-left), +x face (lower-right), top
        self.poly([(x, y + d, z), (x + w, y + d, z), (x + w, y + d, z + h), (x, y + d, z + h)], left, extra=extra)
        self.poly([(x + w, y, z), (x + w, y + d, z), (x + w, y + d, z + h), (x + w, y, z + h)], right, extra=extra)
        self.poly([(x, y, z + h), (x + w, y, z + h), (x + w, y + d, z + h), (x, y + d, z + h)], top, extra=extra)

    def circle(self, c, r, plane, fill=GROUND, n=36, sw=1):
        cx, cy, cz = c
        pts = []
        for i in range(n):
            t = 2 * math.pi * i / n
            u, v = r * math.cos(t), r * math.sin(t)
            pts.append({"xz": (cx + u, cy, cz + v), "yz": (cx, cy + u, cz + v), "xy": (cx + u, cy + v, cz)}[plane])
        self.poly(pts, fill, sw=sw)

    def cylinder_y(self, x, z, r, y0, y1, fill=LEFT):
        # cylinder whose axis runs along y; silhouette = hull of both end caps
        pts = []
        for y in (y0, y1):
            for i in range(48):
                t = 2 * math.pi * i / 48
                pts.append(self.p(x + r * math.cos(t), y, z + r * math.sin(t)))
        hull = convex_hull(pts)
        d = " ".join(f"{a:.1f},{b:.1f}" for a, b in hull)
        self.out.append(f'<polygon points="{d}" fill="{fill}" stroke="{INK}" stroke-width="1"/>')
        self.circle((x, y1, z), r, "xz", fill=TOP)
        self.circle((x, y1, z), r * 0.35, "xz", fill=LEFT)

    def svg(self, w, h, label):
        # fit the drawing into a w x h box, centered, with a little padding
        xs, ys = [q[0] for q in self.seen], [q[1] for q in self.seen]
        pad = 4
        bw, bh = max(xs) - min(xs) + 2 * pad, max(ys) - min(ys) + 2 * pad
        k = max(bw / w, bh / h)
        vx, vy = (min(xs) + max(xs) - w * k) / 2, (min(ys) + max(ys) - h * k) / 2
        body = "\n    ".join(self.out)
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vx:.1f} {vy:.1f} {w*k:.1f} {h*k:.1f}" width="{w}" height="{h}" role="img" aria-label="{label}" '
                f'stroke-linejoin="round" stroke-linecap="round">\n    {body}\n  </svg>')


def convex_hull(pts):
    pts = sorted(set(pts))
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, hi = [], []
    for q in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], q) <= 0: lo.pop()
        lo.append(q)
    for q in reversed(pts):
        while len(hi) >= 2 and cross(hi[-2], hi[-1], q) <= 0: hi.pop()
        hi.append(q)
    return lo[:-1] + hi[:-1]


# Claude Lights state colors (Okabe-Ito, colorblind-safe)
VERMILLION, AMBER, GREEN, MUTED_GREEN, GRAY = "#d55e00", "#e69f00", "#009e73", "#7fc8b2", "#8f8f8f"


def glyph(g, c, kind, color="#ffffff"):
    # screen-aligned glyph centered on a 3D point (iso-aligned strokes would read as slanted)
    x, y = g.p(*c)
    if kind == "!":
        g.out.append(f'<path d="M{x:.1f},{y-4:.1f} V{y+1:.1f} M{x:.1f},{y+3.6:.1f} V{y+3.8:.1f}" stroke="{color}" stroke-width="1.8"/>')
    elif kind == "check":
        g.out.append(f'<path d="M{x-3.5:.1f},{y:.1f} L{x-1:.1f},{y+2.6:.1f} L{x+3.6:.1f},{y-2.6:.1f}" fill="none" stroke="{color}" stroke-width="1.6"/>')
    elif kind == "gear":
        teeth = " ".join(
            f"M{x + 2.4 * math.cos(a):.1f},{y + 2.4 * math.sin(a):.1f} L{x + 4.2 * math.cos(a):.1f},{y + 4.2 * math.sin(a):.1f}"
            for a in (k * math.pi / 3 for k in range(6))
        )
        g.out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="2.4" fill="none" stroke="{color}" stroke-width="1.4"/>')
        g.out.append(f'<path d="{teeth}" stroke="{color}" stroke-width="1.6"/>')


def lamp(g, c, r, fill, kind=None, stroke=INK):
    g.circle(c, r, "xy", fill=fill)
    if stroke != INK:
        g.out[-1] = g.out[-1].replace(f'stroke="{INK}"', f'stroke="{stroke}"')
    if kind:
        glyph(g, c, kind)


def hero():
    g = Iso(22, 0, 0)
    # menu bar strip, floating behind, with the aggregate dot near its right end
    g.box(-3, -6, 3.2, 19, 1.4, 0.25)
    for k, x in enumerate((-1.8, -0.6, 0.6)):
        g.line((x, -5.3, 3.45), (x + 0.6, -5.3, 3.45), stroke=GRAY)
    lamp(g, (13.6, -5.3, 3.45), 0.45, VERMILLION)
    # floating light bar: one dot per session, in launch order
    n, pitch = 6, 2.3
    g.box(0, 0, 0, n * pitch + 0.3, 2.4, 0.7)
    states = [(VERMILLION, "!"), (AMBER, "gear"), (GREEN, "gear"), (GREEN, "check"), (GRAY, None), (GROUND, None)]
    for i, (fill, kind) in enumerate(states):
        c = (0.15 + pitch * (i + 0.5), 1.2, 0.7)
        g.circle(c, 0.88, "xy", fill=LEFT)  # socket
        lamp(g, c, 0.66, fill, kind, stroke=GRAY if fill == GROUND else INK)
    # dashed lead from the menu bar dot down to the waiting session
    g.line((13.6, -5.3, 3.2), (1.3, 1.2, 1.5), stroke=VERMILLION, extra='stroke-dasharray="2 3"')
    return g.svg(640, 300, "Claude Lights: a floating bar of status dots below the macOS menu bar")


def window(g, x, y, z, w, h, kind):
    """An upright app window standing in the x-z plane; its face (plane y + 0.2) faces the viewer's lower left."""
    g.box(x, y, z, w, 0.2, h)
    fy = y + 0.2
    def f(u, v):
        return (x + u, fy, z + v)
    g.line(f(0, h - 0.6), f(w, h - 0.6))  # title bar
    for k in range(3):
        g.circle(f(0.35 + k * 0.32, h - 0.3), 0.09, "xz", fill=LEFT)
    if kind == "terminal":
        for r in range(6):
            v = h - 1.1 - r * 0.55
            g.line(f(0.4, v), f(w * (0.35 + 0.1 * (r % 4)), v), stroke=GRAY)
        return f
    # browser: address bar, a hero block and text lines
    g.poly([f(0.4, h - 0.95), f(w - 0.4, h - 0.95), f(w - 0.4, h - 1.35), f(0.4, h - 1.35)], fill=LEFT)
    g.poly([f(0.4, h - 1.7), f(w * 0.55, h - 1.7), f(w * 0.55, h - 3.2), f(0.4, h - 3.2)], fill=LEFT)
    for r in range(4):
        v = h - 1.9 - r * 0.4
        g.line(f(w * 0.62, v), f(w - 0.5 - (r % 2) * 0.6, v), stroke=GRAY)
    return f


def desk(g):
    # the screen itself: one upright panel behind every window
    g.box(-0.8, -0.8, -0.9, 10.4, 0.3, 7.4, left=TOP)
    g.line((-0.8, -0.5, 6.1), (9.6, -0.5, 6.1))  # menu bar


def hidden():
    g = Iso(13, 0, 0)
    desk(g)
    term = window(g, 0, 0, 0, 7, 5, "terminal")
    # herdr's status lives inside the terminal, in the corner the browser is about to cover
    for k, fill in enumerate((VERMILLION, AMBER, GREEN)):
        g.circle(term(3.6 + k * 0.6, 2.2), 0.2, "xz", fill=fill)
    window(g, 3.4, 2.2, 0, 7.4, 4.6, "browser")
    # dashed outlines where the covered dots sit: the status is there, you just can't see it
    for k in range(3):
        cx, cz = 3.6 + k * 0.6, 2.2
        pts = [(cx + 0.2 * math.cos(t), 0.2, cz + 0.2 * math.sin(t)) for t in (2 * math.pi * i / 24 for i in range(24))]
        g.poly(pts, fill="none", stroke=GRAY, extra='stroke-dasharray="1.5 1.5"')
    return g.svg(360, 260, "Status inside a terminal: a browser window in front covers the terminal and the status dots inside it")


def floating():
    g = Iso(13, 0, 0)
    desk(g)
    window(g, 0, 0, 0, 7, 5, "terminal")
    window(g, 3.4, 2.2, 0, 7.4, 4.6, "browser")
    # Claude Lights: a small always-on-top bar in front of everything
    bx, by, bz = 7.8, 3.6, 5.0
    g.box(bx, by, bz, 3.4, 0.3, 0.8)
    for k, fill in enumerate((VERMILLION, AMBER, GREEN, GRAY)):
        g.circle((bx + 0.5 + k * 0.8, by + 0.3, bz + 0.4), 0.26, "xz", fill=fill)
    # and a notification card when a session needs you
    nx, nz = 7.2, 1.5
    g.box(nx, by, nz, 4.0, 0.2, 1.2, top=TOP)
    g.circle((nx + 0.5, by + 0.2, nz + 0.6), 0.25, "xz", fill=VERMILLION)
    g.line((nx + 1.0, by + 0.2, nz + 0.8), (nx + 3.4, by + 0.2, nz + 0.8))
    g.line((nx + 1.0, by + 0.2, nz + 0.4), (nx + 2.8, by + 0.2, nz + 0.4), stroke=GRAY)
    return g.svg(360, 260, "Status on the desktop: a small always-on-top light bar and a notification float in front of the browser")


def restore():
    """Save / Restore: a dashed snapshot of three panes, an arrow, and the same panes rebuilt solid."""
    g = Iso(12, 0, 0)
    dash = 'stroke-dasharray="3 3"'
    def panes(ox, solid):
        g.box(ox, 0, 0, 7.2, 3.6, 0.4, **({} if solid else dict(top="none", left="none", right="none", extra=dash)))
        for k in range(3):
            x = ox + 0.4 + k * 2.2
            if solid:
                g.box(x, 0.5, 0.4, 1.8, 2.6, 2.2)
                for r in range(3):
                    z = 2.2 - r * 0.5
                    g.line((x + 0.25, 3.1, z), (x + 1.4 - (r % 2) * 0.4, 3.1, z), stroke=GRAY)
                g.circle((x + 0.35, 3.1, 2.35), 0.14, "xz", fill=[GREEN, AMBER, GREEN][k])
            else:
                g.box(x, 0.5, 0.4, 1.8, 2.6, 2.2, top="none", left="none", right="none", extra=dash)
    panes(0, solid=False)
    (x1, y1), (x2, y2) = g.p(7.6, 1.8, 1.6), g.p(10.2, 1.8, 1.6)
    g.out.append(f'<path d="M{x1:.1f},{y1:.1f} L{x2:.1f},{y2:.1f}" stroke="{INK}" stroke-width="1.2"/>')
    g.out.append(f'<path d="M{x2 - 7:.1f},{y2 - 7:.1f} L{x2:.1f},{y2:.1f} L{x2 - 9:.1f},{y2 + 1:.1f}" '
                 f'fill="none" stroke="{INK}" stroke-width="1.2"/>')
    panes(10.6, solid=True)
    return g.svg(400, 250, "Save and Restore: a dashed snapshot of three tmux panes rebuilt as solid panes")


def details():
    """Right-click a light: a menu card hangs from the bar with labeled rows, a summary and Close."""
    g = Iso(13, 0, 0)
    # the floating bar, upright like a window, with the right-clicked light in vermillion
    bx, by, bz = 0, 0, 5.6
    g.box(bx, by, bz, 4.2, 0.3, 0.9)
    for k, fill in enumerate((GREEN, VERMILLION, AMBER, GRAY)):
        g.circle((bx + 0.6 + k * 1.0, by + 0.3, bz + 0.45), 0.28, "xz", fill=fill)
    # the menu card, in front of the bar and below the clicked light
    mx, my, mz, mw, mh = 1.2, 1.4, 0, 9.0, 5.0
    g.box(mx, my, mz, mw, 0.2, mh)
    fy = my + 0.2
    def f(u, v):
        return (mx + u, fy, mz + v)
    g.line(f(0.4, mh - 0.5), f(4.2, mh - 0.5))  # title
    g.line(f(0, mh - 0.9), f(mw, mh - 0.9), stroke=GRAY)
    def row(v, value_end):
        g.line(f(0.4, v), f(1.6, v), stroke=GRAY)  # label column
        g.line(f(2.2, v), f(value_end, v))
    row(mh - 1.35, 7.0)                # Directory
    row(mh - 1.8, 5.6)                 # Summary source
    for r, end in enumerate((8.4, 8.0, 5.2)):
        g.line(f(2.2, mh - 2.2 - r * 0.38), f(end, mh - 2.2 - r * 0.38), stroke=GRAY)  # wrapped summary
    row(mh - 3.45, 6.4)                # Status
    row(mh - 3.9, 5.8)                 # Runs in
    g.line(f(0, mh - 4.3), f(mw, mh - 4.3), stroke=GRAY)
    g.line(f(0.4, 0.35), f(3.0, 0.35), stroke=VERMILLION, sw=1.4)  # Close
    # a dashed lead from the clicked light down to the card
    g.line((bx + 1.6, by + 0.3, bz), (mx + 0.6, fy, mh), stroke=VERMILLION, extra='stroke-dasharray="2 3"')
    return g.svg(400, 250, "Right-click a light: a menu with the session's directory, summary, status, location and a Close item")


def close():
    """Close: a tmux window of two panes; Claude's pane is gone (dashed), the shell beside it stays."""
    g = Iso(12, 0, 0)
    dash = 'stroke-dasharray="3 3"'
    g.box(0, 0, 0, 5.2, 3.6, 0.4)
    # Claude's pane, closed: only a dashed outline is left
    g.box(0.4, 0.5, 0.4, 2.0, 2.6, 2.6, top="none", left="none", right="none", extra=dash)
    # the shell pane next to it keeps running
    g.box(2.8, 0.5, 0.4, 2.0, 2.6, 2.6)
    for r in range(4):
        z = 2.6 - r * 0.5
        g.line((3.05, 3.1, z), (4.2 - (r % 2) * 0.5, 3.1, z), stroke=GRAY)
    # a cross over where Claude was
    (x, y) = g.p(1.4, 3.1, 1.7)
    g.out.append(f'<path d="M{x-6:.1f},{y-6:.1f} L{x+6:.1f},{y+6:.1f} M{x+6:.1f},{y-6:.1f} L{x-6:.1f},{y+6:.1f}" '
                 f'stroke="{VERMILLION}" stroke-width="1.6"/>')
    return g.svg(400, 250, "Close: Claude's tmux pane is removed while the shell pane beside it stays open")


def usage():
    """Usage meter: the menu bar dot with a half-full bar beside it, and the menu's Usage rows below."""
    g = Iso(13, 0, 0)
    # the menu bar strip, upright, with the aggregate dot and its vertical meter
    sx, sy, sz = 0, 0, 5.6
    g.box(sx, sy, sz, 6.0, 0.3, 0.9)
    fy0 = sy + 0.3
    for k, x in enumerate((0.5, 1.4)):
        g.line((x, fy0, sz + 0.45), (x + 0.5, fy0, sz + 0.45), stroke=GRAY)  # other menu bar items
    dx = 3.6
    g.circle((dx, fy0, sz + 0.45), 0.3, "xz", fill=AMBER)
    mx0, mz0, mz1 = dx + 0.55, sz + 0.15, sz + 0.75
    g.poly([(mx0, fy0, mz0), (mx0 + 0.22, fy0, mz0), (mx0 + 0.22, fy0, mz1), (mx0, fy0, mz1)], fill=TOP)
    g.poly([(mx0, fy0, mz0), (mx0 + 0.22, fy0, mz0), (mx0 + 0.22, fy0, mz0 + 0.3), (mx0, fy0, mz0 + 0.3)], fill=INK)
    # the menu card hanging below, its Usage section on top
    cx, cy, cz, cw, ch = 1.6, 1.4, 0, 9.0, 5.0
    g.box(cx, cy, cz, cw, 0.2, ch)
    fy = cy + 0.2
    def f(u, v):
        return (cx + u, fy, cz + v)
    g.line(f(0.4, ch - 0.5), f(1.6, ch - 0.5), stroke=GRAY)   # "Usage"
    g.line(f(5.6, ch - 0.5), f(7.8, ch - 0.5), stroke=GRAY)   # "Updated just now"
    (rx, ry) = g.p(*f(8.4, ch - 0.5))                          # refresh arrow
    g.out.append(f'<path d="M{rx + 3:.1f},{ry - 1.5:.1f} A3.2,3.2 0 1 1 {rx + 1:.1f},{ry - 3:.1f}" '
                 f'fill="none" stroke="{INK}" stroke-width="1.1"/>')
    for r, used in enumerate((0.5, 0.25, 0.15)):              # 5h session, weekly, credit
        v = ch - 1.1 - r * 0.95
        g.line(f(0.4, v), f(2.6, v))                           # title
        g.line(f(5.2, v), f(8.6, v), stroke=GRAY)              # "N% left · resets …"
        g.line(f(0.4, v - 0.42), f(8.6, v - 0.42), stroke=GRAY)                    # meter track
        g.line(f(0.4, v - 0.42), f(0.4 + 8.2 * used, v - 0.42), stroke=INK, sw=2)  # used share
    g.line(f(0, 1.2), f(cw, 1.2), stroke=GRAY)                 # the session list follows
    g.line(f(0.4, 0.8), f(4.0, 0.8))
    g.line(f(0.4, 0.4), f(3.4, 0.4))
    g.line((dx, fy0, sz), (cx + 2.0, fy, ch), stroke=AMBER, extra='stroke-dasharray="2 3"')
    return g.svg(400, 250, "Usage: a small bar beside the menu bar dot fills as the 5-hour limit is used; the menu lists what is left of each limit")


def bar_lights(g, x, y, z, states, pitch=2.3, r=0.66):
    """The floating light bar lying flat: one socketed lamp per session."""
    g.box(x, y, z, len(states) * pitch + 0.3, 2.4, 0.7)
    for i, (fill, kind) in enumerate(states):
        c = (x + 0.15 + pitch * (i + 0.5), y + 1.2, z + 0.7)
        g.circle(c, r + 0.22, "xy", fill=LEFT)  # socket
        lamp(g, c, r, fill, kind, stroke=GRAY if fill == GROUND else INK)


ALL_STATES = [(VERMILLION, "!"), (GREEN, "check"), (GREEN, "gear"), (GRAY, None), (AMBER, "gear"), (GROUND, None)]


def lights():
    """A light per session: the bar with every state, in launch order."""
    g = Iso(22, 0, 0)
    bar_lights(g, 0, 0, 0, ALL_STATES)
    return g.svg(400, 250, "The floating light bar: waiting, done, answered with a background task, idle, running, just started")


def jump():
    """One click to jump: a dashed lead from the red light to that session's terminal window."""
    g = Iso(13, 0, 0)
    f = window(g, 0, 0, 0, 7.4, 5.2, "terminal")
    # tmux status line along the bottom, the session's window marked
    g.line(f(0.3, 0.5), f(7.1, 0.5), stroke=GRAY)
    g.poly([f(1.4, 0.32), f(2.4, 0.32), f(2.4, 0.68), f(1.4, 0.68)], fill=VERMILLION)
    # the permission prompt the session is waiting on
    g.circle(f(0.6, 1.3), 0.2, "xz", fill=VERMILLION)
    g.line(f(1.0, 1.3), f(4.6, 1.3))
    # the light bar off to the right, above the window; its red light was clicked
    bx, by, bz = 8.6, -1.0, 6.4
    g.box(bx, by, bz, 3.6, 0.3, 0.9)
    for k, fill in enumerate((VERMILLION, GREEN, AMBER, GRAY)):
        g.circle((bx + 0.5 + k * 0.85, by + 0.3, bz + 0.45), 0.3, "xz", fill=fill)
    g.line((bx + 0.5, by + 0.3, bz + 0.1), f(2.4, 0.68), stroke=VERMILLION, extra='stroke-dasharray="2 3"')
    return g.svg(400, 250, "One click to jump: clicking the red light brings that session's terminal window forward on its tmux window")


def notify():
    """A notification banner: the app's three lights, a title and a line of detail."""
    g = Iso(13, 0, 0)
    nx, ny, nz, nw, nh = 0, 0, 0, 9.0, 2.4
    g.box(nx, ny, nz, nw, 0.3, nh)
    fy = ny + 0.3
    def f(u, v):
        return (nx + u, fy, nz + v)
    # app icon: the three state lights on a white plate
    g.poly([f(0.4, 0.4), f(2.0, 0.4), f(2.0, 2.0), f(0.4, 2.0)], fill=TOP)
    for (u, v), fill in (((0.85, 1.45), VERMILLION), ((1.55, 1.45), AMBER), ((1.2, 0.85), GREEN)):
        g.circle(f(u, v), 0.3, "xz", fill=fill)
    g.line(f(2.5, 1.7), f(5.6, 1.7), sw=1.4)  # "blog is done"
    g.line(f(2.5, 1.15), f(8.2, 1.15), stroke=GRAY)
    g.line(f(2.5, 0.7), f(6.4, 0.7), stroke=GRAY)
    # sound waves from the banner's corner
    for k in range(3):
        r = 0.4 + k * 0.35
        pts = [(nw + 0.3 + r * math.cos(t), fy, nh - 0.2 + r * math.sin(t)) for t in (math.pi * (-0.25 + i / 20 * 0.5) for i in range(11))]
        d = " ".join(f"{a:.1f},{b:.1f}" for a, b in (g.p(*q) for q in pts))
        g.out.append(f'<polyline points="{d}" fill="none" stroke="{GRAY}" stroke-width="1"/>')
    return g.svg(400, 250, "A notification banner with the Claude Lights icon and a ping")


if __name__ == "__main__":
    out = pathlib.Path(__file__).resolve().parent.parent / "site" / "art"
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in {"hero": hero, "hidden": hidden, "floating": floating, "restore": restore,
                     "details": details, "close": close, "lights": lights, "jump": jump,
                     "notify": notify, "usage": usage}.items():
        (out / f"{name}.svg").write_text(fn() + "\n")
        print(f"wrote site/art/{name}.svg")
