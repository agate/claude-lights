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


if __name__ == "__main__":
    out = pathlib.Path(__file__).resolve().parent.parent / "site" / "art"
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in {"hero": hero, "hidden": hidden, "floating": floating}.items():
        (out / f"{name}.svg").write_text(fn() + "\n")
        print(f"wrote site/art/{name}.svg")
