"""What is on each page of the demo vault. Page coordinates are points from the top left of a US
Letter page (612 x 792). Every note is original content written for the demo; pictures and the
video are NASA's (public domain, CREDITS.md).

Notes are written oldest first, so the note list (newest first) opens on the showcase notes.
"""
from __future__ import annotations

import math
import random
import subprocess
from pathlib import Path

from hand import Hand

# Inks: chosen to read on white and cream paper and after the app's dark-page inversion.
NAVY = "#1E2A44FF"
BLUE = "#2B58B0FF"
RED = "#C23B3BFF"
GREEN = "#2E7D4FFF"
ORANGE = "#E07B1FFF"
PURPLE = "#6B4FBBFF"
TEAL = "#1F7A8CFF"
GRAY = "#6B7280FF"
BROWN = "#8B5A2BFF"
YELLOW_HI = "#FFD83D70"
BLUE_HI = "#7FB3FF60"
GREEN_HI = "#8EE08E60"
PINK_HI = "#FF8FB160"
# The night-sky page (dark paper).
STAR = "#FFF4D6FF"
SKY_LINE = "#8FA7D9B0"
SKY_TEXT = "#DCE6FFFF"

CREAM = "#FFF8E1"
INK = "#1E2A44"  # text boxes (#RRGGBB)


def hand(fonts, seed, font="caveat"):
    return Hand(fonts, seed, font=font)


# ---------------------------------------------------------------------------------------------
# School / Calculus


def derivatives(v, fonts):
    n = v.note("Derivatives", "School/Calculus", ["lecture", "calculus"], paper="grid", spacing=20,
               line_color="#DCE4F0")
    h = hand(fonts, 11)
    h.text("Derivatives", 48, 78, 40, color=NAVY)
    h.underline(48, 90, 190, color=RED)
    h.text("Oct 7", 500, 70, 20, color=GRAY)
    h.text("slope of the tangent = limit of slopes of secants", 48, 130, 21, color=NAVY)

    # Graph: y = 0.012 (x-100)^2 style parabola in page space.
    ox, oy = 80, 420
    h.arrow(ox - 10, oy, 330, oy, NAVY, 1.4)
    h.arrow(ox, oy + 10, ox, 170, NAVY, 1.4)
    h.text("x", 334, oy + 6, 18, color=NAVY)
    h.text("y", ox - 18, 176, 18, color=NAVY)

    def f(x):
        return oy - 0.0042 * (x - ox) ** 2 - 20

    h.curve(f, ox + 5, 315, NAVY, 2.0)
    x0, x1 = 170, 260
    h.dot(x0, f(x0), 3, RED)
    h.dot(x1, f(x1), 3, RED)
    # secant (red), tangent (blue)
    s = (f(x1) - f(x0)) / (x1 - x0)
    h.line(x0 - 50, f(x0) - 50 * s, x1 + 40, f(x1) + 40 * s, RED, 1.6)
    t = -0.0084 * (x0 - ox)
    h.line(x0 - 70, f(x0) - 70 * t, x0 + 110, f(x0) + 110 * t, BLUE, 2.0)
    h.polyline([[x0, f(x0)], [x1, f(x0)], [x1, f(x1)]], GRAY, 1.2, step=1.5)
    h.text("h", (x0 + x1) / 2 - 4, f(x0) + 20, 18, color=GRAY)
    h.text("f(x+h) - f(x)", x1 + 8, f(x0) - 10, 16, color=GRAY)
    h.text("secant", 226, 236, 17, color=RED)
    h.text("tangent", x0 + 116, f(x0) + 110 * t + 4, 17, color=BLUE)

    v.math(n, r"f'(x) = \lim_{h \to 0} \frac{f(x+h) - f(x)}{h}", at=(360, 200), width=220, color=INK)
    h.ellipse(470, 225, 128, 44, ORANGE, 1.4, wobble=0.4)

    h.text("Rules", 360, 330, 26, color=NAVY)
    h.underline(360, 338, 60, color=GREEN)
    v.math(n, r"\frac{d}{dx}\,x^n = n\,x^{n-1}", at=(362, 352), width=150, color=INK)
    h.text("(sin x)' = cos x", 362, 432, 20, color=NAVY)
    h.text("(eˣ)' = eˣ", 362, 462, 20, color=NAVY)
    h.text("its own derivative!", 470, 462, 16, color=RED)
    h.text("(f g)' = f'g + f g'", 362, 492, 20, color=NAVY)
    h.highlight(358, 480, 132, 18, YELLOW_HI)

    h.text("Example", 48, 520, 24, color=GREEN)
    h.text("f(x) = x³ - 4x", 60, 556, 21, color=NAVY)
    h.text("f'(x) = 3x² - 4", 60, 588, 21, color=NAVY)
    w = h.text("flat where 3x² = 4, so x = ±1.15", 60, 620, 21, color=NAVY)
    h.arrow(60 + w + 8, 612, 60 + w + 44, 600, RED, 1.4)
    h.text("max / min!", 60 + w + 50, 604, 20, color=RED)
    v.text(n, "Notation: f′(x), dy/dx and ḟ all mean the same thing. Leibniz wrote dy/dx; Newton put a dot "
              "over the letter.", at=(48, 668), width=500, size=12, color="#4B5563", italic=True)
    v.draw(n, h.strokes)


def integrals(v, fonts):
    n = v.note("Integrals and Riemann Sums", "School/Calculus", ["lecture", "calculus"], paper="grid", spacing=20,
               line_color="#DCE4F0")
    h = hand(fonts, 12)
    h.text("Integrals = area", 48, 78, 40, color=NAVY)
    h.underline(48, 90, 240, color=GREEN)
    h.text("Oct 14", 500, 70, 20, color=GRAY)

    ox, oy = 70, 400
    h.arrow(ox - 10, oy, 360, oy, NAVY, 1.4)
    h.arrow(ox, oy + 10, ox, 150, NAVY, 1.4)

    def f(x):
        u = (x - ox) / 280
        return oy - (60 + 170 * u * u * (1.6 - u))

    a, b, k = 100, 320, 8
    dx = (b - a) / k
    colors = [BLUE_HI, GREEN_HI]
    for i in range(k):
        x = a + i * dx
        top = f(x)
        # Fill a rectangle with a few marker swipes, then outline it.
        rows = max(1, int((oy - top) / 12))
        for r_ in range(rows):
            y = top + (oy - top) * (r_ + 0.5) / rows
            h._emit([[x + 1, y], [x + dx - 1, y]], colors[i % 2], (oy - top) / rows + 1.5, tool="marker", taper=False,
                    step=4, wobble=0)
        h.rect(x, top, dx, oy - top, BLUE, 1.0)
    h.curve(f, ox + 4, 345, RED, 2.2)
    h.text("a", a - 4, oy + 22, 18, color=NAVY)
    h.text("b", b - 4, oy + 22, 18, color=NAVY)
    h.text("Δx", a + dx * 3 + 4, oy + 22, 17, color=BLUE)
    h.text("y = f(x)", 300, 150, 20, color=RED)
    h.text("left sum: under", 380, 230, 20, color=BLUE)
    h.text("(f is increasing)", 380, 256, 18, color=GRAY)
    h.text("more rectangles", 380, 300, 20, color=NAVY)
    h.text("→ exact area", 380, 326, 20, color=NAVY)
    h.highlight(376, 314, 120, 18, YELLOW_HI)

    v.math(n, r"\int_a^b f(x)\,dx = \lim_{n \to \infty} \sum_{i=1}^{n} f(x_i^*)\,\Delta x", at=(60, 450),
           width=330, color=INK)
    h.text("Fundamental Theorem", 60, 560, 26, color=PURPLE)
    h.star(290, 551, 10, ORANGE)
    v.math(n, r"\int_a^b F'(x)\,dx = F(b) - F(a)", at=(60, 578), width=250, color=INK)
    h.rect(52, 572, 270, 56, PURPLE, 1.4)
    h.text("differentiation and integration", 340, 596, 18, color=PURPLE)
    h.text("undo each other", 340, 620, 18, color=PURPLE)

    h.text("e.g.", 60, 690, 21, color=GRAY)
    v.math(n, r"\int_0^2 x^2\,dx = \frac{8}{3} \approx 2.67", at=(100, 664), width=170, color="#2E7D4F")
    h.text("area under the parabola from 0 to 2", 300, 690, 18, color=GREEN)
    v.draw(n, h.strokes)


PSET = r"""\documentclass[11pt]{article}
\usepackage[letterpaper,margin=1in]{geometry}
\usepackage{amsmath,amssymb}
\usepackage{helvet}\renewcommand{\familydefault}{\sfdefault}
\pagestyle{empty}
\setlength{\parindent}{0pt}
\begin{document}
{\Large\bfseries Calculus I \hfill Problem Set 4}\\[2pt]
{\small Derivatives and the Fundamental Theorem \hfill Due Friday}\\[-4pt]
\rule{\linewidth}{0.6pt}

\textbf{1.} Find $\dfrac{d}{dx}\left(3x^4 - 5x^2 + 7\right)$.\vspace{1.25in}

\textbf{2.} A ball is thrown upward; its height is $h(t) = 20t - 4.9t^2$ meters.
When does it reach its highest point, and how high is it?\vspace{1.6in}

\textbf{3.} Use the product rule to differentiate $f(x) = x^2 \sin x$.\vspace{1.25in}

\textbf{4.} Evaluate $\displaystyle\int_0^{\pi} \sin x \, dx$ and explain what the number means as an area.
\newpage
\textbf{5.} Sketch $y = x^3 - 3x$ and mark its local maximum and minimum.\vspace{3.4in}

\textbf{6.} \emph{Challenge.} Show that $\dfrac{d}{dx}\, e^{x^2} = 2x\,e^{x^2}$ with the chain rule.
\end{document}
"""


def problem_set(v, fonts, work: Path):
    d = work / "pset"
    d.mkdir()
    (d / "pset.tex").write_text(PSET)
    subprocess.run(["pdflatex", "-interaction=batchmode", "pset.tex"], cwd=d, check=True, capture_output=True)
    n = v.import_pdf(d / "pset.pdf", "Problem Set 4", "School/Calculus", ["homework", "calculus"])
    h = hand(fonts, 13)
    # Page 1: answers in blue, the grader's red. (PDF text sits at 1in margins; problems at about
    # y 130, 245, 390, 500.)
    h.text("12x³ - 10x", 100, 175, 24, color=BLUE)
    _check(h, 250, 170)
    h.text("h'(t) = 20 - 9.8t = 0", 100, 292, 22, color=BLUE)
    h.text("t ≈ 2.04 s", 100, 322, 22, color=BLUE)
    h.text("h(2.04) ≈ 20.4 m", 100, 352, 22, color=BLUE)
    h.ellipse(165, 345, 80, 18, RED, 1.4)
    _check(h, 270, 345)
    h.text("f'(x) = 2x sin x + x² cos x", 100, 442, 22, color=BLUE)
    _check(h, 360, 438)
    h.text("= [-cos x] from 0 to π = 2", 100, 540, 22, color=BLUE)
    h.text("= the area under one arch", 120, 572, 20, color=BLUE)
    _check(h, 400, 566)
    h.text("92", 520, 48, 34, color=RED)
    h.line(514, 56, 566, 38, RED, 1.6)
    h.text("100", 548, 66, 20, color=RED)
    h.text("Great work!", 452, 132, 24, color=RED)
    # Page 2: the sketch.
    h.page = 2
    ox, oy = 306, 190
    h.arrow(ox - 160, oy, ox + 160, oy, NAVY, 1.3)
    h.arrow(ox, oy + 96, ox, oy - 100, NAVY, 1.3)
    sx, sy = 62, 30
    h.curve(lambda x: oy - sy * (((x - ox) / sx) ** 3 - 3 * (x - ox) / sx), ox - 2.1 * sx, ox + 2.1 * sx, BLUE, 2.0)
    h.dot(ox - sx, oy - 2 * sy, 3.2, RED)
    h.dot(ox + sx, oy + 2 * sy, 3.2, RED)
    h.text("max (-1, 2)", ox - sx - 40, oy - 2 * sy - 14, 18, color=RED)
    h.text("min (1, -2)", ox + sx - 30, oy + 2 * sy + 26, 18, color=RED)
    _check(h, 480, 170)
    h.text("outside eᵘ, inside u = x²", 100, 400, 21, color=BLUE)
    h.text("→ e^(x²) · 2x", 100, 432, 21, color=BLUE)
    h.text("nice!", 300, 432, 22, color=RED)
    v.draw(n, h.strokes)


def _check(h, x, y):
    h._emit([[x, y - 6], [x + 6, y + 2], [x + 20, y - 16]], RED, 2.2, taper=False, step=1.5)


# ---------------------------------------------------------------------------------------------
# School / Biology


def cell(v, fonts):
    n = v.note("The Animal Cell", "School/Biology", ["lecture", "biology"], paper="blank", background=CREAM)
    h = hand(fonts, 21)
    h.text("The Animal Cell", 48, 78, 40, color=GREEN)
    h.underline(48, 90, 230, color=ORANGE)
    h.text("Oct 9", 500, 70, 20, color=GRAY)
    cx, cy = 290, 320
    # membrane: a wobbly closed blob, drawn twice (phospholipid bilayer)
    pts = []
    for i in range(121):
        a = 2 * math.pi * i / 120
        r = 190 + 14 * math.sin(3 * a + 0.6) + 8 * math.sin(5 * a)
        pts.append([cx + r * math.cos(a) * 1.15, cy + r * math.sin(a) * 0.82])
    h.polyline(pts, GREEN, 2.6, taper=False)
    h.polyline([[cx + (p[0] - cx) * 0.965, cy + (p[1] - cy) * 0.96] for p in pts], GREEN, 1.1, taper=False)
    # nucleus + nucleolus + pores
    h.ellipse(cx - 10, cy - 5, 62, 50, PURPLE, 2.2)
    h.ellipse(cx - 10, cy - 5, 56, 44, PURPLE, 0.9)
    h.ellipse(cx + 5, cy + 2, 16, 13, PURPLE, 1.6)
    for k in range(5):
        h._emit([[cx + 5 - 9 + k * 4, cy - 4 + (k % 2) * 6], [cx + 5 - 7 + k * 4, cy + 6 - (k % 2) * 6]], PURPLE, 1.1)
    # rough ER: wavy bands around the nucleus, with ribosome dots
    for j, r in enumerate((80, 94, 108)):
        h.param(lambda t, r=r: [cx - 10 + r * math.cos(t) + 3 * math.sin(9 * t), cy - 5 + r * 0.82 * math.sin(t)],
                1.9, 3.6, 70, BLUE, 1.5)
        for t in [1.95 + 0.17 * i for i in range(10)]:
            h.dot(cx - 10 + (r + 5) * math.cos(t), cy - 5 + (r + 5) * 0.82 * math.sin(t), 1.4, NAVY)
    # Golgi: stacked arcs
    for j in range(5):
        h.param(lambda t, j=j: [cx + 150 + 34 * math.cos(t), cy - 60 + j * 8 + 16 * math.sin(t)], 3.5, 5.9, 40,
                ORANGE, 2.0)
    for k in range(3):
        h.ellipse(cx + 196 + k * 6, cy - 66 + k * 18, 4, 4, ORANGE, 1.2)
    # mitochondria
    for (mx, my, rot) in [(cx - 150, cy + 70, 0.4), (cx + 110, cy + 82, -0.3), (cx + 45, cy - 118, -0.2),
                          (cx + 10, cy + 118, 0.1)]:
        h.ellipse(mx, my, 36, 17, RED, 2.0, rot=rot)
        zz = []
        for i in range(13):
            u = -28 + i * 56 / 12
            w = 9 if i % 2 else -9
            zz.append([mx + u * math.cos(rot) - w * math.sin(rot), my + u * math.sin(rot) + w * math.cos(rot)])
        h.polyline(zz, RED, 1.1, taper=False, step=1.2)
    # lysosomes / vesicles
    for (lx, ly) in [(cx + 70, cy - 150), (cx - 190, cy - 20), (cx + 200, cy + 40)]:
        h.ellipse(lx, ly, 11, 11, TEAL, 1.6)
        h.dot(lx - 2, ly + 1, 1.6, TEAL)
    # free ribosomes
    rnd = random.Random(5)
    for _ in range(26):
        a, r = rnd.uniform(0, 2 * math.pi), rnd.uniform(120, 175)
        h.dot(cx + r * math.cos(a) * 1.1, cy + r * math.sin(a) * 0.75, 1.3, NAVY)

    def label(text, tx, ty, px, py, color):
        h.text(text, tx, ty, 19, color=color)
        h.line(px, py, tx + (0 if tx < px else -6) + (h.width(text, 19) + 6 if tx < px else 0), ty - 6, GRAY, 0.9)

    label("nucleus", 40, 170, cx - 50, cy - 40, PURPLE)
    label("rough ER", 40, 240, cx - 100, cy - 30, BLUE)
    label("mitochondrion", 30, 470, cx - 165, cy + 90, RED)
    label("Golgi", 470, 200, cx + 170, cy - 56, ORANGE)
    label("lysosome", 470, 470, cx + 205, cy + 46, TEAL)
    label("cell membrane", 420, 530, cx + 150, cy + 112, GREEN)
    v.text(n, "**Organelles to know**\n"
              "- **Nucleus**: DNA; the cell's control center\n"
              "- **Mitochondria**: make ATP (cellular respiration)\n"
              "- **Rough ER**: ribosomes build proteins here\n"
              "- **Golgi**: packages and ships proteins\n"
              "- **Lysosomes**: digest worn-out parts",
           at=(56, 580), width=360, size=12.5, color=INK, markdown=True)
    h.text("plants also have:", 430, 600, 19, color=GREEN)
    h.text("cell wall, chloroplasts,", 430, 626, 19, color=GREEN)
    h.text("a big central vacuole", 430, 652, 19, color=GREEN)
    h.ellipse(500, 622, 92, 46, GREEN, 1.0, wobble=0.5)
    v.draw(n, h.strokes)


def photosynthesis(v, fonts, media):
    n = v.note("Photosynthesis", "School/Biology", ["lecture", "biology"], paper="cornell", cue_width=140,
               summary_height=120)
    h = hand(fonts, 22)
    h.text("Photosynthesis", 160, 60, 36, color=GREEN)
    h.text("Oct 16", 520, 56, 18, color=GRAY)
    cues = [("Where?", 110), ("Inputs and", 190), ("outputs?", 214), ("Two stages", 330), ("Why care?", 520)]
    for t, y in cues:
        h.text(t, 16, y, 21, color=PURPLE)
    h.text("in chloroplasts", 160, 110, 21, color=NAVY)
    h.text("(thylakoids + stroma)", 300, 110, 18, color=GRAY)
    v.math(n, r"6\,\mathrm{CO_2} + 6\,\mathrm{H_2O} \xrightarrow{\text{light}} \mathrm{C_6H_{12}O_6} + 6\,\mathrm{O_2}",
           at=(160, 150), width=320, color="#2E7D4F")
    h.text("light energy → chemical energy (glucose)", 160, 232, 20, color=NAVY)
    h.highlight(156, 220, 300, 18, GREEN_HI)
    # Two stages: a little flow diagram
    h.rect(160, 270, 160, 90, ORANGE, 1.6)
    h.text("light reactions", 170, 295, 19, color=ORANGE)
    h.text("H₂O → O₂", 172, 322, 18, color=NAVY)
    h.text("make ATP, NADPH", 172, 346, 17, color=NAVY)
    h.rect(400, 270, 170, 90, BLUE, 1.6)
    h.text("Calvin cycle", 412, 295, 19, color=BLUE)
    h.text("CO₂ → sugar", 414, 322, 18, color=NAVY)
    h.text("uses ATP, NADPH", 414, 346, 17, color=NAVY)
    h.arrow(322, 300, 396, 300, NAVY, 1.4)
    h.arrow(396, 335, 322, 335, NAVY, 1.4)
    h.text("ATP", 345, 292, 15, color=GRAY)
    h.text("ADP", 345, 352, 15, color=GRAY)
    # sun doodle
    sx, sy = 540, 100
    h.ellipse(sx, sy, 14, 14, ORANGE, 2)
    for k in range(8):
        a = k * math.pi / 4
        h.line(sx + 19 * math.cos(a), sy + 19 * math.sin(a), sx + 28 * math.cos(a), sy + 28 * math.sin(a), ORANGE, 1.6)
    v.image(n, media["plankton"], frame=(160, 395, 220, 173))
    h.text("phytoplankton bloom", 395, 420, 19, color=TEAL)
    h.text("north of Iceland", 395, 444, 19, color=TEAL)
    h.text("seen from orbit!", 395, 468, 19, color=TEAL)
    h.arrow(392, 480, 368, 500, TEAL, 1.3)
    h.text("about half of Earth's O₂", 160, 614, 21, color=NAVY)
    h.text("comes from the ocean", 160, 640, 21, color=NAVY)
    h.underline(160, 648, 180, color=RED)
    v.text(n, "Image: NASA/GSFC/Jeff Schmaltz (MODIS). Public domain.", at=(160, 572), width=300, size=9, color="#6B7280")
    # summary band (bottom 120 pt)
    h.text("Summary:", 20, 700, 21, color=PURPLE)
    h.paragraph("Plants and algae use light to turn CO₂ and water into sugar and oxygen; the light reactions make "
                "ATP that powers the Calvin cycle.", 110, 700, 470, 19, leading=1.35, color=NAVY)
    v.draw(n, h.strokes)


# ---------------------------------------------------------------------------------------------
# School / Astronomy


def conics(v, fonts):
    n = v.note("Conic Sections", "School/Astronomy", ["lecture", "astronomy", "math"], paper="dot", spacing=18,
               background=CREAM)
    h = hand(fonts, 31)
    h.text("Conic Sections", 48, 78, 40, color=NAVY)
    h.underline(48, 90, 220, color=RED)
    h.text("Oct 15", 500, 70, 20, color=GRAY)
    h.text("slice a double cone with a plane", 48, 122, 20, color=GRAY)
    # The double cone
    ax, ay = 150, 300
    h.line(ax - 95, ay - 150, ax + 95, ay + 150, NAVY, 1.8)
    h.line(ax + 95, ay - 150, ax - 95, ay + 150, NAVY, 1.8)
    h.ellipse(ax, ay - 150, 95, 16, NAVY, 1.6)
    h.ellipse(ax, ay + 150, 95, 16, NAVY, 1.6, dashed=False)
    h.ellipse(ax, ay - 70, 44, 7.5, BLUE, 2.2)  # circle
    h.ellipse(ax + 6, ay - 105, 64, 13, GREEN, 2.2, rot=-0.32)  # ellipse
    # parabola (one nappe) and hyperbola (both)
    h.param(lambda t: [ax + 30 + 22 * t * t * 0 + 40 * t, ay + 120 - 70 * (1 - t * t)], -0.95, 0.95, 50, ORANGE, 2.2)
    h.text("circle", ax - 100, ay - 66, 18, color=BLUE)
    h.text("ellipse", ax + 70, ay - 120, 18, color=GREEN)
    h.text("parabola", ax + 82, ay + 90, 18, color=ORANGE)
    # Four panels
    panels = [("circle", "e = 0", BLUE), ("ellipse", "0 < e < 1", GREEN), ("parabola", "e = 1", ORANGE),
              ("hyperbola", "e > 1", RED)]
    for i, (name, e, col) in enumerate(panels):
        px, py = 320 + (i % 2) * 140, 150 + (i // 2) * 135
        cx, cy = px + 60, py + 60
        h.line(px + 4, cy, px + 116, cy, GRAY, 0.8)
        h.line(cx, py + 6, cx, py + 112, GRAY, 0.8)
        if i == 0:
            h.ellipse(cx, cy, 34, 34, col, 2)
            h.dot(cx, cy, 2.6, NAVY)
        elif i == 1:
            h.ellipse(cx, cy, 46, 28, col, 2)
            h.dot(cx - 36, cy, 2.6, NAVY)
            h.dot(cx + 36, cy, 2.6, NAVY)
        elif i == 2:
            h.param(lambda t: [cx - 20 + 14 * t * t, cy + 26 * t], -1.9, 1.9, 50, col, 2)
            h.dot(cx - 10, cy, 2.6, NAVY)
        else:
            h.param(lambda t: [cx + 18 * math.cosh(t), cy + 24 * math.sinh(t)], -1.5, 1.5, 50, col, 2)
            h.param(lambda t: [cx - 18 * math.cosh(t), cy + 24 * math.sinh(t)], -1.5, 1.5, 50, col, 2)
            h.line(cx - 50, cy - 66, cx + 50, cy + 66, GRAY, 0.8)
            h.line(cx - 50, cy + 66, cx + 50, cy - 66, GRAY, 0.8)
        h.text(name, px + 6, py + 132, 18, color=col)
        h.text(e, px + 70, py + 132, 15, color=NAVY)

    h.text("Polar form, focus at the origin:", 48, 476, 21, color=NAVY)
    v.math(n, r"r(\theta) = \frac{\ell}{1 + e\cos\theta}", at=(60, 492), width=170, color=INK)
    h.text("e = c / a", 270, 528, 24, color=RED)
    h.text("eccentricity", 270, 552, 17, color=RED)
    v.text(n, "**Why it matters:** every orbit under gravity alone is a conic. Bound orbits are ellipses; "
              "an object moving at exactly escape speed follows a parabola, and a faster one a hyperbola.",
           at=(380, 482), width=190, size=11.5, color=INK, markdown=True)
    # Halley's comet sketch
    h.text("Halley's comet: e = 0.967", 48, 628, 22, color=NAVY)
    h.highlight(44, 616, 240, 18, YELLOW_HI)
    hx, hy = 400, 680
    h.ellipse(hx, hy, 160, 40, BLUE, 1.5, dashed=True)
    sun = hx - math.sqrt(160 ** 2 - 40 ** 2)
    h.ellipse(sun, hy, 7, 7, ORANGE, 2.4)
    h.ellipse(sun, hy, 12, 12, GREEN, 1.0)  # Earth's orbit (1 AU at this scale)
    h.dot(hx + 140, hy - 19, 3, NAVY)
    for k in range(5):
        h.line(hx + 143, hy - 19 + (k - 2) * 2, hx + 175, hy - 24 + (k - 2) * 5, BLUE, 0.8)
    h.text("Earth's orbit", sun - 30, hy + 58, 15, color=GREEN)
    h.arrow(sun - 4, hy + 44, sun - 2, hy + 16, GREEN, 1.0, head=6)
    h.text("Sun", sun - 36, hy + 5, 15, color=ORANGE)
    h.text("Earth e = 0.017", 48, 662, 19, color=GRAY)
    v.draw(n, h.strokes)


def kepler(v, fonts, media, work: Path):
    n = v.note("Kepler's Laws", "School/Astronomy", ["lecture", "astronomy"], paper="grid", spacing=18,
               line_color="#E2E8F2", pages=2, favorite=True)
    h = hand(fonts, 32)
    h.text("Kepler's Laws", 48, 80, 42, color=NAVY)
    h.underline(48, 92, 210, color=RED)
    h.text("Oct 21", 500, 70, 20, color=GRAY)
    h.text("1. Orbits are ellipses, with the Sun at one focus", 48, 128, 22, color=NAVY)
    cx, cy, a, b = 300, 262, 160, 98
    c = math.sqrt(a * a - b * b)
    sx = cx - c
    # Law 2: equal areas, shaded
    def on(E):
        return [cx + a * math.cos(E), cy + b * math.sin(E)]

    for (e0, e1, col) in [(math.radians(152), math.radians(208), YELLOW_HI), (math.radians(-11), math.radians(11), BLUE_HI)]:
        steps = 14
        for i in range(steps + 1):
            p = on(e0 + (e1 - e0) * i / steps)
            h._emit([[sx, cy], p], col, 7, tool="marker", taper=False, step=4, wobble=0)
    h.ellipse(cx, cy, a, b, NAVY, 2.2)
    for (e0, e1) in [(math.radians(152), math.radians(208)), (math.radians(-11), math.radians(11))]:
        h.line(sx, cy, *on(e0), GRAY, 0.9)
        h.line(sx, cy, *on(e1), GRAY, 0.9)
    # the Sun
    for r in (9, 6, 3):
        h.ellipse(sx, cy, r, r, ORANGE, 2.4)
    for k in range(10):
        q = k * math.pi / 5
        h.line(sx + 13 * math.cos(q), cy + 13 * math.sin(q), sx + 19 * math.cos(q), cy + 19 * math.sin(q), ORANGE, 1.4)
    # empty focus
    h.line(cx + c - 4, cy - 4, cx + c + 4, cy + 4, GRAY, 1.3)
    h.line(cx + c - 4, cy + 4, cx + c + 4, cy - 4, GRAY, 1.3)
    # planet
    pE = math.radians(-58)
    px, py = on(pE)
    h.ellipse(px, py, 7, 7, BLUE, 2.4)
    h.dot(px, py, 3, BLUE)
    h.arrow(px + 4, py + 10, px + 30, py + 24, BLUE, 1.4, head=7)
    # a, b, c
    h.line(cx, cy, cx + a, cy, RED, 1.1)
    h.text("a", cx + a / 2 - 10, cy + 24, 19, color=RED)
    h.line(cx, cy, cx, cy - b, GREEN, 1.1)
    h.text("b", cx + 6, cy - b / 2, 19, color=GREEN)
    h.text("c", sx + c / 2 - 4, cy + 20, 19, color=PURPLE)
    h.text("perihelion", 40, cy + 6, 17, color=NAVY)
    h.text("aphelion", cx + a + 8, cy + 34, 17, color=NAVY)
    h.text("A1", sx - 28, cy - 52, 19, color=BROWN)
    h.text("A2", cx + a + 12, cy - 4, 19, color=BLUE)

    h.text("2. Equal areas in equal times:", 48, 408, 22, color=NAVY)
    h.text("A1 = A2: fastest near the Sun", 60, 438, 21, color=NAVY)
    h.highlight(56, 426, 236, 18, YELLOW_HI)
    h.text("3. Harmonic law:", 48, 488, 22, color=NAVY)
    v.math(n, r"T^2 = \frac{4\pi^2}{G M}\, a^3", at=(70, 504), width=150, color=INK)
    h.rect(60, 498, 170, 64, RED, 1.5)
    h.text("in years and AU:  T² = a³", 250, 538, 21, color=PURPLE)
    h.text("Mars: a = 1.52 AU", 60, 610, 21, color=NAVY)
    h.text("T = √(1.52³) ≈ 1.88 yr", 60, 640, 21, color=NAVY)
    _check(h, 268, 636)
    h.text("Saturn: a = 9.5 AU", 60, 690, 21, color=NAVY)
    h.text("T ≈ 29.5 yr", 60, 720, 21, color=NAVY)
    v.image(n, media["saturn"], frame=(330, 600, 240, 112))
    h.text("Saturn, backlit by the Sun (Cassini)", 330, 736, 16, color=GRAY)
    v.text(n, "Kepler found these laws (1609, 1619) in Tycho Brahe's observations of Mars. Newton later derived "
              "all three from his law of gravitation.", at=(370, 396), width=200, size=11, color="#4B5563",
           italic=True)
    v.voice_note(n, "kepler-recap", KEPLER_MEMO_FRAME)

    # Page 2: Artemis II
    h.page = 2
    h.text("Artemis II: around the Moon", 48, 80, 36, color=NAVY)
    h.underline(48, 92, 330, color=BLUE)
    clip = work / "artemis-ii-launch.mp4"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "26", "-i", str(media["artemis-launch"]),
                    "-t", "22", "-vf", "scale=960:-2", "-c:v", "libx264", "-preset", "slow", "-crf", "24",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart",
                    "-map_metadata", "-1", str(clip)], check=True)
    v.video(n, clip, page=2, at=(48, 112), width=330, poster_time=14)
    h.text("Launch: Apr 1, 2026", 396, 140, 22, color=RED)
    h.text("Pad 39B, 6:35 pm", 396, 168, 19, color=NAVY)
    h.text("first crew to the Moon", 396, 206, 19, color=NAVY)
    h.text("since Apollo 17 (1972)", 396, 230, 19, color=NAVY)
    h.star(560, 196, 10, ORANGE)
    h.text("Free-return trajectory", 48, 350, 26, color=PURPLE)
    ex, ey, mx, my = 130, 480, 470, 480
    h.ellipse(ex, ey, 26, 26, BLUE, 2.4)
    h.ellipse(ex, ey, 40, 13, GREEN, 1.3, rot=-0.2)
    h.text("Earth", ex - 22, ey + 52, 19, color=BLUE)
    h.ellipse(mx, my, 13, 13, GRAY, 2.2)
    h.ellipse(mx - 4, my - 3, 3, 2.5, GRAY, 1.0)
    h.ellipse(mx + 5, my + 4, 2, 2, GRAY, 1.0)
    h.text("Moon", mx - 18, my + 44, 19, color=GRAY)
    # figure-eight path: out above, around the far side, back below
    def fig8(t):
        x = (ex + mx) / 2 + 205 * math.cos(t) / (1 + math.sin(t) ** 2)
        y = ey - 95 * math.sin(t) * math.cos(t) / (1 + math.sin(t) ** 2) * 1.0
        return [x, y]
    h.param(fig8, math.pi + 0.15, 3 * math.pi - 0.15, 160, RED, 1.9, wobble=0.15)
    h.arrow(*fig8(math.pi * 1.62), *fig8(math.pi * 1.64), RED, 1.6, head=9)
    h.arrow(*fig8(math.pi * 2.38), *fig8(math.pi * 2.40), RED, 1.6, head=9)
    h.text("far side flyby", mx - 10, my - 62, 18, color=RED)
    h.text("TLI burn", ex + 34, ey - 50, 18, color=GREEN)
    h.text("no big burn needed to come home:", 48, 610, 21, color=NAVY)
    h.text("the Moon's gravity bends the path back", 48, 638, 21, color=NAVY)
    h.highlight(44, 626, 330, 18, PINK_HI)
    v.image(n, media["moon-artemis"], page=2, frame=(400, 560, 172, 117))
    h.text("Snow Moon over the", 400, 700, 16, color=GRAY)
    h.text("rocket, Feb 1", 400, 720, 16, color=GRAY)
    v.text(n, "Video and photos: NASA (public domain).", at=(48, 740), width=300, size=9, color="#6B7280", page=2)
    v.draw(n, h.strokes)


# Orion, with RA in hours and Dec in degrees, and visual magnitude.
STARS = {
    "Betelgeuse": (5.919, 7.41, 0.5), "Bellatrix": (5.419, 6.35, 1.6), "Alnitak": (5.679, -1.94, 1.8),
    "Alnilam": (5.604, -1.20, 1.7), "Mintaka": (5.533, -0.30, 2.2), "Saiph": (5.796, -9.67, 2.1),
    "Rigel": (5.242, -8.20, 0.1), "Meissa": (5.585, 9.93, 3.4), "pi3": (4.830, 6.96, 3.2), "pi2": (4.843, 8.90, 4.3),
    "pi4": (4.853, 5.60, 3.7), "pi5": (4.904, 2.44, 3.7), "mu": (6.040, 9.65, 4.1), "xi": (6.200, 14.21, 4.4),
    "nu": (6.126, 14.77, 4.4), "chi1": (5.906, 20.28, 4.4), "M42": (5.588, -5.39, 4.0),
    "Aldebaran": (4.599, 16.51, 0.85), "Sirius": (6.752, -16.72, -1.46),
}
FIGURE = [("Betelgeuse", "Alnitak"), ("Bellatrix", "Mintaka"), ("Alnitak", "Alnilam"), ("Alnilam", "Mintaka"),
          ("Alnitak", "Saiph"), ("Mintaka", "Rigel"), ("Betelgeuse", "Bellatrix"), ("Betelgeuse", "Meissa"),
          ("Bellatrix", "Meissa"), ("Bellatrix", "pi3"), ("pi2", "pi3"), ("pi3", "pi4"), ("pi4", "pi5"),
          ("Betelgeuse", "mu"), ("mu", "xi"), ("xi", "nu"), ("nu", "chi1")]


def night_sky(v, fonts):
    n = v.note("Night Sky Log", "School/Astronomy", ["astronomy", "observing"], paper="blank", background="#121B33",
               pageless=True, favorite=True)
    h = hand(fonts, 33)
    h.text("Night Sky Log", 48, 80, 42, color=SKY_TEXT)
    h.underline(48, 92, 210, color="#F2C14EFF")
    h.text("Oct 20, 9:40 pm, clear, cold", 330, 76, 19, color=SKY_TEXT)
    h.text("Orion is up in the east!", 48, 128, 22, color=SKY_TEXT)

    def proj(ra, dec):
        x = 306 - (ra - 5.55) * 15 * math.cos(math.radians(dec)) * 14
        y = 420 - dec * 14
        return x, y

    rnd = random.Random(7)
    for _ in range(90):  # faint background stars
        x, y = rnd.uniform(40, 570), rnd.uniform(150, 690)
        h.dot(x, y, rnd.choice([0.6, 0.7, 0.9, 1.1]), "#C8D3F0B0")
    for a_, b_ in FIGURE:
        x1, y1 = proj(*STARS[a_][:2])
        x2, y2 = proj(*STARS[b_][:2])
        d = math.hypot(x2 - x1, y2 - y1)
        u = 10 / d
        h.line(x1 + (x2 - x1) * u, y1 + (y2 - y1) * u, x2 - (x2 - x1) * u, y2 - (y2 - y1) * u, SKY_LINE, 1.0)
    colors = {"Betelgeuse": "#FFB36BFF", "Rigel": "#BFD8FFFF", "Aldebaran": "#FFC58AFF", "Sirius": "#E4F0FFFF"}
    for name, (ra, dec, mag) in STARS.items():
        x, y = proj(ra, dec)
        if name == "M42":
            for r in (7, 5, 3):
                h.ellipse(x, y, r * 1.3, r, "#F2A6C8C0", 1.2)
            continue
        r = max(1.2, 5.2 - mag * 1.05)
        h.dot(x, y, r, colors.get(name, STAR))
        if mag < 1:
            for k in range(4):
                q = k * math.pi / 2 + 0.3
                h.line(x + (r + 3) * math.cos(q), y + (r + 3) * math.sin(q), x + (r + 9) * math.cos(q),
                       y + (r + 9) * math.sin(q), colors.get(name, STAR), 0.9)
    lbl = {"Betelgeuse": (-60, -16), "Rigel": (12, 18), "Bellatrix": (-28, -14), "Saiph": (12, 18),
           "Aldebaran": (12, -10), "Sirius": (14, 6)}
    for name, (dx, dy) in lbl.items():
        x, y = proj(*STARS[name][:2])
        h.text(name, x + dx if dx is not None else x - 8 - h.width(name, 18), y + dy, 18, color=SKY_TEXT)
    x, y = proj(*STARS["M42"][:2])
    h.text("M42 nebula", x + 14, y + 6, 16, color="#F2A6C8FF")
    h.text("belt", proj(*STARS["Mintaka"][:2])[0] - 50, proj(*STARS["Mintaka"][:2])[1] - 8, 16, color=SKY_TEXT)
    # belt points to Sirius and Aldebaran
    bx, by = proj(*STARS["Alnitak"][:2])
    sx_, sy_ = proj(*STARS["Sirius"][:2])
    h.arrow(bx + 12, by + 10, sx_ - 14, sy_ - 10, "#F2C14EC0", 1.2)
    mx, my = proj(*STARS["Mintaka"][:2])
    axx, ayy = proj(*STARS["Aldebaran"][:2])
    h.arrow(mx - 10, my - 8, axx + 12, ayy + 12, "#F2C14EC0", 1.2)

    y0 = 730
    for line in ["Betelgeuse: red supergiant, about 550 light years",
                 "Rigel: blue supergiant, brighter but farther",
                 "M42 looked like a fuzzy patch in binoculars",
                 "Follow the belt down-left to Sirius, up-right to Aldebaran"]:
        h.text("·  " + line, 48, y0, 20, color=SKY_TEXT)
        y0 += 32
    # Saturn through the club telescope
    y0 += 30
    h.text("Saturn at 60x (club telescope)", 48, y0, 26, color="#F2C14EFF")
    h.ellipse(170, y0 + 90, 34, 30, "#F5DFA8FF", 2.0)
    h.ellipse(170, y0 + 92, 82, 20, "#F5DFA8FF", 1.6, rot=-0.12)
    h.ellipse(170, y0 + 92, 66, 14, "#E8C987C0", 1.0, rot=-0.12)
    h.dot(290, y0 + 70, 2.2, STAR)
    h.text("Titan?", 298, y0 + 74, 18, color=SKY_TEXT)
    h.text("rings tilted, Cassini gap", 330, y0 + 110, 19, color=SKY_TEXT)
    h.text("barely visible", 330, y0 + 134, 19, color=SKY_TEXT)
    y0 += 200
    h.text("Moon this week", 48, y0, 26, color="#F2C14EFF")
    for i, (day, frac) in enumerate([("Mon", 0.15), ("Tue", 0.3), ("Wed", 0.5), ("Thu", 0.68), ("Fri", 0.85)]):
        mx_, my_ = 90 + i * 105, y0 + 70
        h.ellipse(mx_, my_, 30, 30, "#C8D3F080", 1.0)
        # the lit part (waxing, right side): limb + terminator
        h.param(lambda t, mx_=mx_, my_=my_: [mx_ + 30 * math.cos(t), my_ + 30 * math.sin(t)], -math.pi / 2,
                math.pi / 2, 40, "#F5EBC8FF", 2.0)
        k = 1 - 2 * frac
        h.param(lambda t, mx_=mx_, my_=my_, k=k: [mx_ + 30 * k * math.cos(t), my_ + 30 * math.sin(t)], -math.pi / 2,
                math.pi / 2, 40, "#F5EBC8FF", 1.4)
        for j in range(9):  # shade the lit part
            yy = my_ - 26 + j * 6.5
            half = math.sqrt(max(0.0, 900 - (yy - my_) ** 2))
            x_l = mx_ + k * half
            h._emit([[x_l + 2, yy], [mx_ + half - 2, yy]], "#F5EBC860", 5, tool="marker", taper=False, step=3, wobble=0)
        h.text(day, mx_ - 14, my_ + 56, 18, color=SKY_TEXT)
    h.text("first quarter on Wednesday: best craters along the terminator", 48, y0 + 170, 19, color=SKY_TEXT)
    v.draw(n, h.strokes)


# ---------------------------------------------------------------------------------------------
# Personal (a printed hand: Kalam)


FOCACCIA_MEMO_FRAME = (398, 590, 200, 64)
KEPLER_MEMO_FRAME = (374, 454, 188, 60)


def focaccia(v, fonts):
    n = v.note("Sunday Focaccia", "Personal/Recipes", ["recipe", "baking"], paper="ruled", spacing=28,
               background=CREAM, line_color="#E8DCC0", margin_left=56, margin_color="#F0B8A8", favorite=True)
    h = hand(fonts, 41, font="kalam")
    h.text("Sunday Focaccia", 70, 50, 34, color=BROWN)
    h.text("serves 8 · 24 h with the fridge rest", 70, 80, 17, color=GRAY)
    h.text("Ingredients", 70, 134, 24, color=ORANGE)
    items = [("500 g bread flour", True), ("400 g warm water", True), ("10 g salt", True),
             ("4 g instant yeast", True), ("60 ml olive oil (+ more!)", False), ("rosemary, flaky salt", False),
             ("cherry tomatoes, olives", False)]
    y = 166
    for t, done in items:
        h.checkbox(72, y - 14, 13, done, GREEN)
        h.text(t, 96, y, 19, color=NAVY)
        y += 28
    h.text("Method", 330, 134, 24, color=ORANGE)
    steps = ["mix flour, water, yeast;", "rest 30 min, add salt", "4 folds, 30 min apart", "",
             "oil a tin, fridge overnight", "warm 2-3 h, dimple with", "oily fingers", "bake 230 °C, 22 min"]
    y = 166
    num = 1
    for i, s in enumerate(steps):
        if not s:
            continue
        lead = f"{num}. " if i in (0, 2, 4, 5, 7) else "    "
        if lead.strip():
            num += 1
        h.text(lead + s, 330, y, 18, color=NAVY)
        y += 28
    h.highlight(330, y - 42, 200, 18, YELLOW_HI)
    # The pan, from above, with dimples and toppings
    px, py, pw, ph = 90, 400, 300, 190
    h.rect(px, py, pw, ph, GRAY, 2.0)
    h.rect(px + 8, py + 8, pw - 16, ph - 16, "#D9A55BFF", 1.4)
    rnd = random.Random(3)
    for i in range(7):
        for j in range(4):
            x = px + 30 + i * 40 + rnd.uniform(-6, 6)
            y_ = py + 30 + j * 42 + rnd.uniform(-6, 6)
            h.ellipse(x, y_, 5, 4, "#C08A3EFF", 1.2)
    for _ in range(9):
        x, y_ = px + rnd.uniform(30, pw - 30), py + rnd.uniform(30, ph - 30)
        h.ellipse(x, y_, 7, 7, RED, 1.8)
        h.dot(x, y_, 2.4, "#E25B5BFF")
    for _ in range(10):
        x, y_ = px + rnd.uniform(30, pw - 30), py + rnd.uniform(30, ph - 30)
        a = rnd.uniform(0, math.pi)
        h.line(x, y_, x + 14 * math.cos(a), y_ + 14 * math.sin(a), GREEN, 2.0)
        for k in range(3):
            bx, by = x + 4 * k * math.cos(a), y_ + 4 * k * math.sin(a)
            h.line(bx, by, bx + 5 * math.cos(a + 1), by + 5 * math.sin(a + 1), GREEN, 1.0)
    for _ in range(5):
        x, y_ = px + rnd.uniform(30, pw - 30), py + rnd.uniform(30, ph - 30)
        h.ellipse(x, y_, 5, 4, "#3B2F4AFF", 2.0)
    h.text("dimples hold the oil!", 410, 440, 19, color=RED)
    h.arrow(405, 448, 360, 470, RED, 1.3)
    h.text("tomatoes cut side up", 410, 520, 19, color=RED)
    h.arrow(405, 526, 360, 540, RED, 1.3)
    h.text("Notes", 70, 650, 24, color=ORANGE)
    h.text("Oct 5: a bit pale, bake 4 min longer next time", 70, 682, 18, color=NAVY)
    h.text("Oct 12: perfect. Crispy bottom! ★★★★★", 70, 710, 18, color=NAVY)
    v.draw(n, h.strokes)
    v.voice_note(n, "focaccia-memo", FOCACCIA_MEMO_FRAME)


def ramen(v, fonts):
    n = v.note("Weeknight Miso Ramen", "Personal/Recipes", ["recipe", "quick"], paper="dot", spacing=20)
    h = hand(fonts, 42, font="kalam")
    h.text("Weeknight Miso Ramen", 48, 70, 32, color=RED)
    h.text("25 min · 2 bowls", 48, 100, 18, color=GRAY)
    # bowl
    bx, by = 420, 230
    h.param(lambda t: [bx + 130 * math.cos(t), by + 95 * math.sin(t)], 0.05, math.pi - 0.05, 60, NAVY, 2.4)
    h.ellipse(bx, by, 132, 24, NAVY, 2.0)
    h.line(bx - 40, by + 98, bx + 40, by + 98, NAVY, 2.2)
    for k in range(7):  # noodles, inside the rim
        h.param(lambda t, k=k: [bx - 108 + t, by - 6 + 4 * math.sin(t / 8 + k * 1.3) + k * 2.4], 0, 216, 60,
                "#E0B04AFF", 1.3)
    h.ellipse(bx - 60, by - 4, 20, 13, NAVY, 1.4)  # egg
    h.ellipse(bx - 60, by - 4, 8, 7, ORANGE, 2.6)
    h.ellipse(bx - 25, by - 2, 19, 12, NAVY, 1.4)
    h.ellipse(bx - 25, by - 2, 8, 7, ORANGE, 2.6)
    for k in range(5):  # scallions
        h.ellipse(bx + 20 + k * 11, by - 8 + (k % 2) * 6, 4, 3, GREEN, 1.6)
    h.rect(bx + 70, by - 18, 32, 22, "#2F3E2FFF", 1.6)  # nori
    h.line(bx + 40, by - 120, bx + 150, by - 10, BROWN, 2.4)
    h.line(bx + 58, by - 128, bx + 160, by - 22, BROWN, 2.4)
    y = 150
    h.text("For the broth", 48, y, 22, color=ORANGE)
    for t in ["2 tbsp white miso", "1 tbsp tahini", "1 tsp chili crisp", "3 cups stock", "garlic + ginger, grated"]:
        y += 28
        h.text("·  " + t, 56, y, 18, color=NAVY)
    y += 46
    h.text("Bowl", 48, y, 22, color=ORANGE)
    for t in ["fresh noodles (3 min)", "jammy egg: 6 ½ min boil", "scallions, nori, sesame", "corn or bok choy"]:
        y += 28
        h.text("·  " + t, 56, y, 18, color=NAVY)
    h.highlight(52, y - 72, 200, 18, YELLOW_HI)
    v.text(n, "**Tip:** whisk the miso into a ladle of hot stock off the heat. Boiling miso dulls the flavor.",
           at=(300, 410), width=260, size=12.5, color=INK, markdown=True)
    h.text("make extra eggs for lunches", 300, 500, 19, color=GREEN)
    h.arrow(296, 494, 250, 470, GREEN, 1.3)
    h.text("Variations", 48, 600, 22, color=ORANGE)
    for i, t in enumerate(["spicy: + 1 tsp gochujang", "vegan: veggie stock, crispy tofu, no egg",
                           "leftover roast chicken + corn", "kids: skip the chili crisp"]):
        h.text("·  " + t, 56, 632 + 30 * i, 18, color=NAVY)
    h.text("rating", 430, 600, 18, color=GRAY)
    h.text("★★★★", 430, 630, 22, color=ORANGE)
    v.draw(n, h.strokes)


def iceland(v, fonts, media):
    n = v.note("Iceland Ring Road", "Personal/Travel", ["trip", "iceland"], paper="blank", pageless=True)
    h = hand(fonts, 51, font="kalam")
    h.text("Iceland: Ring Road", 48, 70, 34, color=TEAL)
    h.text("8 days · March", 48, 100, 18, color=GRAY)
    # Iceland's coast, roughly (lon, lat), and the stops.
    coast = [(-22.7, 63.8), (-21.9, 64.15), (-22.1, 64.32), (-22.6, 64.75), (-23.9, 64.85), (-22.4, 64.98),
             (-22.6, 65.25), (-24.4, 65.5), (-24.0, 65.85), (-23.2, 66.25), (-22.4, 66.45), (-21.6, 66.0),
             (-21.2, 65.6), (-20.9, 65.75), (-20.4, 66.1), (-19.8, 66.12), (-19.4, 65.75), (-18.8, 66.15),
             (-18.2, 66.05), (-18.1, 65.7), (-17.7, 66.05), (-16.6, 66.18), (-16.0, 66.52), (-15.0, 66.25),
             (-14.5, 66.38), (-14.8, 65.9), (-14.0, 65.75), (-13.6, 65.45), (-13.65, 65.0), (-14.4, 64.65),
             (-15.2, 64.25), (-16.4, 63.85), (-17.9, 63.55), (-19.0, 63.4), (-20.3, 63.65), (-21.4, 63.85),
             (-22.7, 63.8)]
    ox, oy, W, H = 50, 140, 500, 330

    def at(lon, lat):
        return [ox + (lon + 24.6) / 11.2 * W, oy + (66.6 - lat) / 3.3 * H]

    h.polyline([at(*p) for p in coast], NAVY, 2.0, taper=False, wobble=0.5)
    stops = [("Reykjavík", -21.9, 64.15, ("R", 6)), ("Vík", -19.0, 63.42, ("L", -6)),
             ("Jökulsárlón", -16.2, 64.05, ("R", 14)), ("Seyðisfjörður", -14.0, 65.26, ("L", 20)),
             ("Mývatn", -17.0, 65.6, ("R", 18)), ("Akureyri", -18.1, 65.68, ("L", 20)),
             ("Snæfellsnes", -23.0, 64.85, ("R", 20))]
    route = [at(lon, lat) for _, lon, lat, _ in stops] + [at(-21.9, 64.15)]
    # dashed route
    for a_, b_ in zip(route, route[1:]):
        d = math.hypot(b_[0] - a_[0], b_[1] - a_[1])
        k = max(2, int(d / 14))
        for i in range(0, k, 2):
            p = [a_[0] + (b_[0] - a_[0]) * i / k, a_[1] + (b_[1] - a_[1]) * i / k]
            q = [a_[0] + (b_[0] - a_[0]) * (i + 1) / k, a_[1] + (b_[1] - a_[1]) * (i + 1) / k]
            h.line(*p, *q, RED, 1.6)
    for name, lon, lat, (side, dy) in stops:
        X, Y = at(lon, lat)
        h.dot(X, Y, 3.4, RED)
        h.text(name, X + 8 if side == "R" else X - 8 - h.width(name, 16), Y + dy, 16, color=NAVY)
    vx, vy = at(-16.8, 64.42)
    h.ellipse(vx, vy, 50, 20, "#9BC3E6FF", 1.2)
    h.text("Vatnajökull", vx - 34, vy + 5, 14, color=BLUE)
    v.image(n, media["aurora"], frame=(48, 490, 300, 200))
    h.text("aurora forecast:", 370, 520, 20, color=GREEN)
    h.text("Kp 5 on day 3!", 370, 546, 20, color=GREEN)
    h.text("(this one is from the", 370, 586, 16, color=GRAY)
    h.text("Space Station, NASA)", 370, 608, 16, color=GRAY)
    h.arrow(366, 620, 340, 640, GRAY, 1.2)
    y = 740
    h.text("Plan", 48, y, 24, color=TEAL)
    days = ["D1  land KEF, Blue Lagoon, Reykjavík", "D2  Golden Circle: Þingvellir, Geysir, Gullfoss",
            "D3  south coast, Seljalandsfoss, Vík", "D4  glacier lagoon + Diamond Beach",
            "D5  east fjords", "D6  Mývatn baths, Dettifoss", "D7  Akureyri, whale watching",
            "D8  Snæfellsnes, back to KEF"]
    for d in days:
        y += 30
        h.text(d, 56, y, 18, color=NAVY)
    h.highlight(52, 808, 250, 18, YELLOW_HI)
    y += 50
    h.text("Pack", 48, y, 24, color=TEAL)
    for i, (t, done) in enumerate([("wool base layers", True), ("crampons / microspikes", True),
                                   ("swimsuit (hot pots!)", False), ("headlamp", False), ("power bank", True)]):
        y += 30
        h.checkbox(58, y - 13, 13, done, GREEN)
        h.text(t, 82, y, 18, color=NAVY)
    v.draw(n, h.strokes)


def grand_canyon(v, fonts, media):
    n = v.note("Grand Canyon Weekend", "Personal/Travel", ["trip", "hiking"], paper="ruled", spacing=26,
               line_color="#DCE4F0")
    h = hand(fonts, 52, font="kalam")
    h.text("Grand Canyon Weekend", 48, 64, 32, color=ORANGE)
    h.text("South Rim · Nov 7-9", 48, 94, 18, color=GRAY)
    v.image(n, media["grand-canyon"], frame=(48, 116, 270, 180))
    h.text("from the ISS!", 330, 140, 20, color=NAVY)
    h.text("the whole canyon in", 330, 166, 18, color=GRAY)
    h.text("one photo (NASA)", 330, 190, 18, color=GRAY)
    h.arrow(326, 134, 306, 146, NAVY, 1.2, head=7)
    h.text("Bright Angel Trail, elevation", 48, 350, 22, color=NAVY)
    ox, oy = 80, 540
    h.arrow(ox - 6, oy, 540, oy, NAVY, 1.3)
    h.arrow(ox, oy + 6, ox, 360, NAVY, 1.3)
    prof = [(0, 0), (0.08, -0.2), (0.2, -0.45), (0.32, -0.55), (0.45, -0.72), (0.6, -0.78), (0.72, -0.86),
            (0.85, -0.95), (1.0, -1.0)]
    pts = [[ox + 10 + x * 430, 385 - y * 140] for x, y in prof]
    h.polyline(pts, BROWN, 2.2, wobble=0.6)
    h.text("rim 6,860 ft", ox + 14, 380, 16, color=BROWN)
    h.text("Indian Garden", ox + 228, 530, 16, color=GREEN)
    h.dot(ox + 10 + 0.6 * 430, 385 + 0.78 * 140, 3, GREEN)
    h.text("river 2,450 ft", ox + 350, 492, 16, color=BLUE)
    h.text("down: 2 h  ·  up: 4+ h (!)", 48, 590, 21, color=RED)
    h.underline(48, 598, 230, color=RED)
    h.text("start before sunrise, 3 L water each", 48, 630, 19, color=NAVY)
    h.text("sunset at Hopi Point", 48, 660, 19, color=NAVY)
    h.star(250, 654, 8, ORANGE)
    h.text("breakfast at El Tovar", 48, 690, 19, color=NAVY)
    v.draw(n, h.strokes)


def bed_plan(v, fonts, media):
    n = v.note("Spring Bed Plan", "Personal/Garden", ["garden", "plan"], paper="grid", spacing=22,
               line_color="#DDE8DA", background="#FBFFF7")
    h = hand(fonts, 61, font="kalam")
    h.text("Raised bed plan: spring", 48, 64, 32, color=GREEN)
    h.text("4 × 8 ft, one square = 1 ft", 48, 94, 17, color=GRAY)
    gx, gy, s = 66, 120, 56
    h.rect(gx, gy, 8 * s, 4 * s, BROWN, 2.6)
    for i in range(1, 8):
        h.line(gx + i * s, gy + 2, gx + i * s, gy + 4 * s - 2, "#C9A27AFF", 0.8)
    for j in range(1, 4):
        h.line(gx + 2, gy + j * s, gx + 8 * s - 2, gy + j * s, "#C9A27AFF", 0.8)
    plan = {"T": [(0, 0), (0, 1), (1, 0), (1, 1)], "B": [(0, 2), (1, 2), (0, 3)], "L": [(2, 0), (3, 0), (2, 1), (3, 1)],
            "C": [(4, 0), (5, 0), (4, 1), (5, 1)], "Z": [(6, 0), (7, 0), (6, 1), (7, 1), (6, 2), (7, 2)],
            "P": [(2, 2), (3, 2), (4, 2), (5, 2)], "M": [(1, 3), (2, 3), (3, 3), (4, 3), (5, 3), (6, 3), (7, 3)]}
    style = {"T": (RED, 1, 18), "B": (GREEN, 4, 7), "L": ("#6FAF4FFF", 4, 8), "C": (ORANGE, 9, 4),
             "Z": ("#E85D9EFF", 1, 15), "P": ("#5E9C3AFF", 6, 5), "M": ("#E8A33DFF", 1, 13)}
    for k, cells in plan.items():
        col, per, r = style[k]
        for (i, j) in cells:
            cx, cy = gx + i * s + s / 2, gy + j * s + s / 2
            if per == 1:
                h.ellipse(cx, cy, r, r, col, 1.8)
                h.dot(cx, cy, 2.2, col)
            else:
                g = int(math.sqrt(per) + 0.99)
                for q in range(per):
                    qx, qy = q % g, q // g
                    h.ellipse(cx + (qx - (g - 1) / 2) * s / (g + 0.5), cy + (qy - (g - 1) / 2) * s / (g + 0.5), r, r, col,
                              1.3)
    legend = [("T", "tomatoes (cages!)"), ("B", "basil"), ("L", "lettuce"), ("C", "carrots"), ("Z", "zinnias"),
              ("P", "snap peas, trellis N"), ("M", "marigolds (edge)")]
    y = 380
    for i, (k, name) in enumerate(legend):
        col = style[k][0]
        x = 66 + (i % 2) * 250
        if i % 2 == 0 and i:
            y += 30
        h.ellipse(x + 6, y - 6, 7, 7, col, 2)
        h.text(name, x + 22, y, 18, color=NAVY)
    v.image(n, media["zinnias"], frame=(330, 520, 240, 160))
    h.text("zinnias grown from seeds", 66, 560, 19, color="#C2477FFF")
    w = h.text("that flew on the Space Station!", 66, 586, 19, color="#C2477FFF")
    h.arrow(66 + w + 6, 578, 324, 590, "#C2477FFF", 1.3, head=7)
    w = h.text("sow after last frost (~May 10)", 66, 640, 19, color=NAVY)
    h.highlight(62, 628, w + 8, 18, YELLOW_HI)
    h.text("Photo: NASA/Ben Smegelsky", 330, 700, 14, color=GRAY)
    v.draw(n, h.strokes)


def tomato_log(v, fonts):
    n = v.note("Tomato Log", "Personal/Garden", ["garden", "log"], paper="ruled", spacing=28, line_color="#E3E8E0")
    h = hand(fonts, 62, font="kalam")
    h.text("Tomato Log: Sungold + Brandywine", 48, 50, 28, color=RED)
    rows = [("May 12", "8 cm", "planted out, windy"), ("May 26", "21 cm", "first true leaves big"),
            ("Jun 9", "45 cm", "staked, pinched suckers"), ("Jun 23", "78 cm", "first flowers!"),
            ("Jul 7", "104 cm", "green fruit x 12"), ("Jul 21", "121 cm", "FIRST RIPE SUNGOLD")]
    h.text("date", 56, 112, 20, color=GRAY)
    h.text("height", 150, 112, 20, color=GRAY)
    h.text("notes", 250, 112, 20, color=GRAY)
    h.line(140, 92, 140, 112 + 28 * len(rows), GRAY, 0.8)
    h.line(240, 92, 240, 112 + 28 * len(rows), GRAY, 0.8)
    for i, (d, ht, note) in enumerate(rows):
        y = 140 + 28 * i
        h.text(d, 56, y, 18, color=NAVY)
        h.text(ht, 150, y, 18, color=GREEN)
        h.text(note, 250, y, 18, color=NAVY if i < 5 else RED)
    h.star(470, 134 + 28 * 5, 9, ORANGE)
    # growth chart
    ox, oy, w, ht_ = 90, 560, 420, 220
    h.arrow(ox - 6, oy, ox + w + 10, oy, NAVY, 1.3)
    h.arrow(ox, oy + 6, ox, oy - ht_ - 10, NAVY, 1.3)
    h.text("cm", ox - 30, oy - ht_ + 4, 16, color=GRAY)
    h.text("weeks", ox + w - 30, oy + 26, 16, color=GRAY)
    vals = [8, 21, 45, 78, 104, 121]
    pts = [[ox + 20 + i * 76, oy - v_ * 1.6] for i, v_ in enumerate(vals)]
    h.polyline(pts, GREEN, 2.2)
    for p in pts:
        h.dot(*p, 3.2, RED)
    h.text("growth spurt", ox + 30, oy - 150, 18, color=PURPLE)
    h.text("after the heat wave", ox + 30, oy - 128, 18, color=PURPLE)
    h.arrow(ox + 120, oy - 118, ox + 160, oy - 82, PURPLE, 1.2)
    w = h.text("Next year: start seeds 2 weeks earlier, more Sungolds!", 48, 620, 19, color=NAVY)
    h.highlight(44, 608, w + 8, 18, YELLOW_HI)
    v.draw(n, h.strokes)


def build(v, fonts, media, work: Path, only: str | None = None):
    """Writes every note, oldest first."""
    steps = [
        ("Tomato Log", lambda: tomato_log(v, fonts)),
        ("Weeknight Miso Ramen", lambda: ramen(v, fonts)),
        ("Grand Canyon Weekend", lambda: grand_canyon(v, fonts, media)),
        ("Spring Bed Plan", lambda: bed_plan(v, fonts, media)),
        ("Iceland Ring Road", lambda: iceland(v, fonts, media)),
        ("Derivatives", lambda: derivatives(v, fonts)),
        ("The Animal Cell", lambda: cell(v, fonts)),
        ("Integrals and Riemann Sums", lambda: integrals(v, fonts)),
        ("Conic Sections", lambda: conics(v, fonts)),
        ("Photosynthesis", lambda: photosynthesis(v, fonts, media)),
        ("Problem Set 4", lambda: problem_set(v, fonts, work)),
        ("Sunday Focaccia", lambda: focaccia(v, fonts)),
        ("Night Sky Log", lambda: night_sky(v, fonts)),
        ("Kepler's Laws", lambda: kepler(v, fonts, media, work)),
    ]
    for title, step in steps:
        if only and only.lower() not in title.lower():
            continue
        print(f"  {title}", flush=True)
        step()
