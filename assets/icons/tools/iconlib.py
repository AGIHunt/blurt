"""Reads the hand-written icon SVGs (assets/icons/*.svg) into one normalized geometry that every target is generated from.

Normalized = a list of layers per icon; each layer is one painted shape:
    Layer(mode="stroke"|"fill", d="M… L… C… Z", opacity=1.0)
where `d` uses absolute M / L / C / Z only (arcs, quadratics, smooth curves, H/V and relative commands are expanded,
<circle>/<ellipse>/<rect>/<line>/<polyline>/<polygon> become paths, and <g transform> is baked into the points).
Strokes keep the family width (1.75) whatever the transform — like `vector-effect: non-scaling-stroke`.

Authoring rules (checked by lint()):
  * viewBox "0 0 24 24"; geometry stays inside 1…23 (strokes included)
  * painted with currentColor only: an element is either a stroke (fill="none") or a fill (stroke="none")
  * stroke-width 1.75 (the root sets it with round caps and joins); `opacity` is allowed for a secondary tone
No dependencies beyond the standard library, so every generator runs with a bare `python3`.
"""
from __future__ import annotations

import math
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

ICONS_DIR = Path(__file__).resolve().parent.parent      # assets/icons
REPO = ICONS_DIR.parent.parent
STROKE = 1.75
NS = "{http://www.w3.org/2000/svg}"
KAPPA = 0.5522847498


@dataclass
class Layer:
    mode: str                 # "stroke" | "fill"
    d: str
    opacity: float = 1.0
    segs: list = field(default_factory=list, repr=False)   # [("M",(x,y)), ("L",(x,y)), ("C",(x1,y1,x2,y2,x,y)), ("Z",())]


@dataclass
class Icon:
    name: str
    layers: list
    title: str = ""
    group: str = "brand"      # "brand" | "generic"
    keywords: str = ""


# --- affine transforms -------------------------------------------------------------------------------------------
def _mul(a, b):
    a1, b1, c1, d1, e1, f1 = a
    a2, b2, c2, d2, e2, f2 = b
    return (a1 * a2 + c1 * b2, b1 * a2 + d1 * b2, a1 * c2 + c1 * d2, b1 * c2 + d1 * d2, a1 * e2 + c1 * f2 + e1,
            b1 * e2 + d1 * f2 + f1)


IDENT = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def parse_transform(s: str | None):
    m = IDENT
    if not s:
        return m
    for name, args in re.findall(r"(\w+)\s*\(([^)]*)\)", s):
        v = [float(x) for x in re.findall(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?", args)]
        if name == "translate":
            t = (1, 0, 0, 1, v[0], v[1] if len(v) > 1 else 0)
        elif name == "scale":
            t = (v[0], 0, 0, v[1] if len(v) > 1 else v[0], 0, 0)
        elif name == "rotate":
            a = math.radians(v[0])
            t = (math.cos(a), math.sin(a), -math.sin(a), math.cos(a), 0, 0)
            if len(v) == 3:
                t = _mul(_mul((1, 0, 0, 1, v[1], v[2]), t), (1, 0, 0, 1, -v[1], -v[2]))
        elif name == "matrix":
            t = tuple(v)
        else:
            raise ValueError(f"unsupported transform {name}")
        m = _mul(m, t)
    return m


def _ap(m, x, y):
    return (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])


# --- path data -----------------------------------------------------------------------------------------------------
_TOK = re.compile(r"[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")


def _arc_to_cubics(x1, y1, rx, ry, phi, fa, fs, x2, y2):
    """SVG endpoint arc → list of cubic segments (x1,y1,x2,y2,x,y)."""
    if rx == 0 or ry == 0:
        return [(x1, y1, x2, y2, x2, y2)]
    rx, ry = abs(rx), abs(ry)
    cp, sp = math.cos(math.radians(phi)), math.sin(math.radians(phi))
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    lam = x1p ** 2 / rx ** 2 + y1p ** 2 / ry ** 2
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx ** 2 * ry ** 2 - rx ** 2 * y1p ** 2 - ry ** 2 * x1p ** 2
    den = rx ** 2 * y1p ** 2 + ry ** 2 * x1p ** 2
    co = math.sqrt(max(0, num / den)) * (-1 if fa == fs else 1)
    cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
    cx, cy = cp * cxp - sp * cyp + (x1 + x2) / 2, sp * cxp + cp * cyp + (y1 + y2) / 2

    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a

    t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not fs and dt > 0:
        dt -= 2 * math.pi
    elif fs and dt < 0:
        dt += 2 * math.pi
    n = max(1, math.ceil(abs(dt) / (math.pi / 2) - 1e-9))
    d = dt / n
    k = 4 / 3 * math.tan(d / 4)
    out = []
    t = t1
    for _ in range(n):
        c1, s1, c2, s2 = math.cos(t), math.sin(t), math.cos(t + d), math.sin(t + d)
        p = lambda ex, ey: (cx + rx * ex * cp - ry * ey * sp, cy + rx * ex * sp + ry * ey * cp)  # noqa: E731
        a = p(c1 - k * s1, s1 + k * c1)
        b = p(c2 + k * s2, s2 - k * c2)
        e = p(c2, s2)
        out.append((*a, *b, *e))
        t += d
    return out


def parse_d(d: str):
    """Path data → absolute segments [("M",(x,y)), ("L",(x,y)), ("C",(…6)), ("Z",())]."""
    toks = _TOK.findall(d)
    i, cmd = 0, None
    x = y = sx = sy = 0.0
    lastc = lastq = None
    segs = []

    def num():
        nonlocal i
        v = float(toks[i])
        i += 1
        return v

    while i < len(toks):
        if re.match(r"[A-Za-z]", toks[i]):
            cmd = toks[i]
            i += 1
        rel = cmd.islower()
        C = cmd.upper()
        ox, oy = (x, y) if rel else (0.0, 0.0)
        if C == "Z":
            segs.append(("Z", ()))
            x, y = sx, sy
            lastc = lastq = None
            continue
        if C == "M":
            x, y = num() + ox, num() + oy
            sx, sy = x, y
            segs.append(("M", (x, y)))
            cmd = "l" if rel else "L"
            lastc = lastq = None
        elif C == "L":
            x, y = num() + ox, num() + oy
            segs.append(("L", (x, y)))
            lastc = lastq = None
        elif C == "H":
            x = num() + (x if rel else 0)
            segs.append(("L", (x, y)))
            lastc = lastq = None
        elif C == "V":
            y = num() + (y if rel else 0)
            segs.append(("L", (x, y)))
            lastc = lastq = None
        elif C == "C":
            x1, y1, x2, y2, ex, ey = num() + ox, num() + oy, num() + ox, num() + oy, num() + ox, num() + oy
            segs.append(("C", (x1, y1, x2, y2, ex, ey)))
            lastc, lastq = (x2, y2), None
            x, y = ex, ey
        elif C == "S":
            x1, y1 = (2 * x - lastc[0], 2 * y - lastc[1]) if lastc else (x, y)
            x2, y2, ex, ey = num() + ox, num() + oy, num() + ox, num() + oy
            segs.append(("C", (x1, y1, x2, y2, ex, ey)))
            lastc, lastq = (x2, y2), None
            x, y = ex, ey
        elif C in "QT":
            if C == "Q":
                qx, qy = num() + ox, num() + oy
            else:
                qx, qy = (2 * x - lastq[0], 2 * y - lastq[1]) if lastq else (x, y)
            ex, ey = num() + ox, num() + oy
            segs.append(("C", (x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y), ex + 2 / 3 * (qx - ex), ey + 2 / 3 * (qy - ey), ex, ey)))
            lastq, lastc = (qx, qy), None
            x, y = ex, ey
        elif C == "A":
            rx, ry, phi, fa, fs = num(), num(), num(), num(), num()
            ex, ey = num() + ox, num() + oy
            for c in _arc_to_cubics(x, y, rx, ry, phi, int(fa), int(fs), ex, ey):
                segs.append(("C", c))
            x, y = ex, ey
            lastc = lastq = None
        else:
            raise ValueError(f"bad path command {cmd}")
    return segs


def _ellipse(cx, cy, rx, ry):
    kx, ky = rx * KAPPA, ry * KAPPA
    return [("M", (cx + rx, cy)),
            ("C", (cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry)),
            ("C", (cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy)),
            ("C", (cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry)),
            ("C", (cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy)),
            ("Z", ())]


def _rect(x, y, w, h, rx, ry):
    if not rx and not ry:
        return [("M", (x, y)), ("L", (x + w, y)), ("L", (x + w, y + h)), ("L", (x, y + h)), ("Z", ())]
    rx = min(rx or ry, w / 2)
    ry = min(ry or rx, h / 2)
    kx, ky = rx * (1 - KAPPA), ry * (1 - KAPPA)
    r, b = x + w, y + h
    return [("M", (x + rx, y)), ("L", (r - rx, y)), ("C", (r - kx, y, r, y + ky, r, y + ry)),
            ("L", (r, b - ry)), ("C", (r, b - ky, r - kx, b, r - rx, b)),
            ("L", (x + rx, b)), ("C", (x + kx, b, x, b - ky, x, b - ry)),
            ("L", (x, y + ry)), ("C", (x, y + ky, x + kx, y, x + rx, y)), ("Z", ())]


def _f(el, k, default=0.0):
    v = el.get(k)
    return float(v) if v not in (None, "") else default


def element_segs(el):
    tag = el.tag.replace(NS, "")
    if tag == "path":
        return parse_d(el.get("d", ""))
    if tag == "circle":
        r = _f(el, "r")
        return _ellipse(_f(el, "cx"), _f(el, "cy"), r, r)
    if tag == "ellipse":
        return _ellipse(_f(el, "cx"), _f(el, "cy"), _f(el, "rx"), _f(el, "ry"))
    if tag == "rect":
        return _rect(_f(el, "x"), _f(el, "y"), _f(el, "width"), _f(el, "height"), _f(el, "rx"), _f(el, "ry"))
    if tag == "line":
        return [("M", (_f(el, "x1"), _f(el, "y1"))), ("L", (_f(el, "x2"), _f(el, "y2")))]
    if tag in ("polyline", "polygon"):
        v = [float(n) for n in re.findall(r"[-+]?(?:\d*\.\d+|\d+\.?)", el.get("points", ""))]
        pts = list(zip(v[::2], v[1::2]))
        s = [("M", pts[0])] + [("L", p) for p in pts[1:]]
        return s + [("Z", ())] if tag == "polygon" else s
    return None


def transform_segs(segs, m):
    if m == IDENT:
        return segs
    out = []
    for c, a in segs:
        if c == "Z":
            out.append((c, a))
        else:
            pts = [_ap(m, a[k], a[k + 1]) for k in range(0, len(a), 2)]
            out.append((c, tuple(v for p in pts for v in p)))
    return out


def fmt(v: float) -> str:
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def segs_to_d(segs) -> str:
    parts = []
    for c, a in segs:
        parts.append(c + (" ".join(fmt(v) for v in a) if a else ""))
    return "".join(parts)


def _style(el, inherited):
    st = dict(inherited)
    for k in ("fill", "stroke", "stroke-width", "opacity"):
        if el.get(k) is not None:
            st[k] = el.get(k)
    for part in (el.get("style") or "").split(";"):
        if ":" in part:
            k, v = (s.strip() for s in part.split(":", 1))
            if k in ("fill", "stroke", "stroke-width", "opacity"):
                st[k] = v
    if el.get("opacity") is not None:
        st["opacity"] = str(float(inherited.get("opacity", "1")) * float(el.get("opacity")))
    return st


def load(path: Path) -> Icon:
    root = ET.parse(path).getroot()
    layers: list[Layer] = []
    title = ""
    t = root.find(f"{NS}title")
    if t is not None and t.text:
        title = t.text.strip()
    group = root.get("data-group", "brand")
    keywords = root.get("data-keywords", "")
    base = {"fill": root.get("fill", "none"), "stroke": root.get("stroke", "currentColor"),
            "stroke-width": root.get("stroke-width", str(STROKE)), "opacity": "1"}

    def walk(el, m, st):
        for ch in el:
            tag = ch.tag.replace(NS, "")
            if tag in ("title", "desc", "defs", "metadata"):
                continue
            cm = _mul(m, parse_transform(ch.get("transform")))
            cst = _style(ch, st)
            if tag == "g":
                walk(ch, cm, cst)
                continue
            segs = element_segs(ch)
            if segs is None:
                raise ValueError(f"{path.name}: unsupported element <{tag}>")
            segs = transform_segs(segs, cm)
            op = float(cst.get("opacity", "1"))
            painted = False
            if cst.get("fill", "none") not in ("none", ""):
                layers.append(Layer("fill", segs_to_d(segs), op, segs))
                painted = True
            if cst.get("stroke", "none") not in ("none", ""):
                if float(cst.get("stroke-width", STROKE)) != STROKE:
                    raise ValueError(f"{path.name}: stroke-width must be {STROKE}")
                layers.append(Layer("stroke", segs_to_d(segs), op, segs))
                painted = True
            if not painted:
                raise ValueError(f"{path.name}: <{tag}> paints nothing")

    walk(root, IDENT, base)
    return Icon(path.stem, layers, title, group, keywords)


def load_all() -> list[Icon]:
    return [load(p) for p in sorted(ICONS_DIR.glob("*.svg"), key=lambda p: p.stem)]


def bbox(icon: Icon):
    """Rough painted bounds (control points included, strokes padded by half the width)."""
    xs, ys = [], []
    for L in icon.layers:
        pad = STROKE / 2 if L.mode == "stroke" else 0
        for c, a in L.segs:
            for k in range(0, len(a), 2):
                xs += [a[k] - pad, a[k] + pad]
                ys += [a[k + 1] - pad, a[k + 1] + pad]
    return min(xs), min(ys), max(xs), max(ys)


def lint(icon: Icon) -> list[str]:
    errs = []
    if not icon.layers:
        errs.append(f"{icon.name}: empty")
    x0, y0, x1, y1 = bbox(icon)
    if x0 < 0.5 or y0 < 0.5 or x1 > 23.5 or y1 > 23.5:
        errs.append(f"{icon.name}: geometry outside the 24 grid's safe area ({fmt(x0)},{fmt(y0)})–({fmt(x1)},{fmt(y1)})")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", icon.name):
        errs.append(f"{icon.name}: file names are kebab-case")
    return errs


def normalized_svg(icon: Icon, color: str = "currentColor", size: int | None = None) -> str:
    """The icon as one self-contained SVG (what the web sprite and the PNG renders use)."""
    wh = f' width="{size}" height="{size}"' if size else ""
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"{wh} fill="none" stroke="{color}" '
           f'stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round">']
    out += [inner_markup(icon, color)]
    out.append("</svg>")
    return "".join(out)


def inner_markup(icon: Icon, color: str = "currentColor") -> str:
    parts = []
    for L in icon.layers:
        op = f' opacity="{fmt(L.opacity)}"' if L.opacity != 1 else ""
        if L.mode == "fill":
            parts.append(f'<path d="{L.d}" fill="{color}" stroke="none"{op}/>')
        else:
            parts.append(f'<path d="{L.d}"{op}/>')
    return "".join(parts)

