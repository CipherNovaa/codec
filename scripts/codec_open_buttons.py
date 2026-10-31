#!/usr/bin/env python3
"""codec's own pixel icon buttons — a drop-in for assets/mechui/icons/iconbtn-*.png.

The private build wears a bought pack recoloured to steel; the public tree
can't redistribute it, so this draws codec's own sheet in the SAME layout
(5 columns × 7 rows of 16-px cells, cell order = IconPlate.qml's `cells`):
a chamfered plate in the steel palette and a glyph per icon, four frames —
idle, hot (lit), press (one px down, the lip gone) and on (pressed, bright).

    python3 scripts/codec_open_buttons.py <out-dir>
"""
import sys
from pathlib import Path

from PIL import Image

OUTLINE = (5, 8, 14, 255)
LIP = (16, 19, 25, 255)
FACE = {"idle": (37, 44, 57, 255), "hot": (52, 61, 78, 255)}
INK = {"idle": (166, 177, 199, 255), "hot": (209, 236, 240, 255)}
EDGE = {"idle": (64, 74, 92, 255), "hot": (86, 98, 120, 255)}

# 10 × 8 glyphs, drawn in the face's middle (x 3..12, y 3..10)
G = {
    "exit": ["...#####..", "...#...#..", ".#.#...#..", "#####..#..", ".#.#...#..", "...#...#..", "...#####..", ".........."],
    "hanger": ["....##....", "...#..#...", ".....#....", "....#.#...", "...#...#..", "..#.....#.", ".#########", ".........."],
    "play": ["..#.......", "..##......", "..###.....", "..####....", "..###.....", "..##......", "..#.......", ".........."],
    "eject": ["....##....", "...####...", "..######..", ".########.", "..........", ".########.", ".########.", ".........."],
    "podium": ["....##....", "....##....", ".######...", ".######.##", ".########.", ".########.", ".########.", ".........."],
    "back": [".......#..", "......##..", ".....###..", "....####..", ".....###..", "......##..", ".......#..", ".........."],
    "pause": ["..##..##..", "..##..##..", "..##..##..", "..##..##..", "..##..##..", "..##..##..", "..##..##..", ".........."],
    "menu": [".########.", "..........", "..........", ".########.", "..........", "..........", ".########.", ".........."],
    "music": ["....#####.", "....#...#.", "....#...#.", "....#...#.", "..###.###.", ".########.", "..##..##..", ".........."],
    "pad": ["..........", ".########.", "##.####.##", "#...##.#.#", "##.####.##", ".###..###.", ".##....##.", ".........."],
    "mute": ["....#.....", "...##.#..#", ".####..##.", ".####..##.", ".####.#..#", "...##.....", "....#.....", ".........."],
    "sound": ["....#.....", "...##..#..", ".####.#.#.", ".####.#.#.", ".####.#.#.", "...##..#..", "....#.....", ".........."],
    "muted": ["....#.....", "...##.....", ".####.#..#", ".####..##.", ".####..##.", "...##.#..#", "....#.....", ".........."],
    "gear": ["...#..#...", "..######..", ".##....##.", "..#.##.#..", "..#.##.#..", ".##....##.", "..######..", "...#..#..."],
    "download": ["....##....", "....##....", "..######..", "...####...", "....##....", "#........#", "##########", ".........."],
    "undo": ["..#.......", ".##.......", "######....", ".##...##..", "..#....##.", ".......##.", "...#####..", ".........."],
    "close": [".##....##.", "..##..##..", "...####...", "....##....", "...####...", "..##..##..", ".##....##.", ".........."],
    "trophy": ["#.######.#", "#.######.#", ".#.####.#.", "...####...", "....##....", "....##....", "..######..", ".........."],
    "mail": ["##########", "##......##", "#.#....#.#", "#..#..#..#", "#...##...#", "#........#", "##########", ".........."],
    "heartEmpty": [".##...##..", "#..#.#..#.", "#...#...#.", "#.......#.", ".#.....#..", "..#...#...", "...#.#....", "....#....."],
    "check": [".........#", "........##", ".......##.", "#.....##..", "##...##...", ".##.##....", "..###.....", "...#......"],
    "trash": ["...####...", ".########.", "..........", "..######..", "..#.##.#..", "..#.##.#..", "..#.##.#..", "..######.."],
    "down": ["..........", "##......##", ".##....##.", "..##..##..", "...####...", "....##....", "..........", ".........."],
    "up": ["..........", "....##....", "...####...", "..##..##..", ".##....##.", "##......##", "..........", ".........."],
    "heart": [".##...##..", "####.####.", "#########.", "#########.", ".#######..", "..#####...", "...###....", "....#....."],
    "plus": ["....##....", "....##....", "....##....", "##########", "##########", "....##....", "....##....", "....##...."],
    "minus": ["..........", "..........", "..........", "##########", "##########", "..........", "..........", ".........."],
    "lock": ["...####...", "..#....#..", "..#....#..", ".########.", ".###..###.", ".###..###.", ".########.", ".........."],
    "unlock": ["...####...", "..#....#..", "..#.......", ".########.", ".###..###.", ".###..###.", ".########.", ".........."],
    "info": ["....##....", "..........", "...###....", "....##....", "....##....", "....##....", "...####...", ".........."],
    "blank": None,
}
ORDER = ["exit", "hanger", "play", "eject", "podium", "back", "pause", "menu", "music", "pad",
         "mute", "sound", "muted", "gear", "download", "undo", "close", "trophy", "mail", "heartEmpty",
         "check", "trash", "down", "up", "heart", "plus", "minus", "lock", "unlock", "info", "blank"]


def plate(img, ox, oy, frame):
    """A 16×16 chamfered plate; `press` drops the face one px onto its lip."""
    pressed = frame in ("press", "on")
    tone = "idle" if frame == "idle" else "hot"
    top = 1 if pressed else 0
    bottom = 15                     # the lip's last row
    face_bottom = 13 if not pressed else 14
    px = img.putpixel

    def inside(x, y, y0, y1):
        # 2-px chamfer at the four corners
        c = min(x, 15 - x)
        r = min(y - y0, y1 - y)
        return not (c + r < 2)

    for y in range(top, bottom + 1):
        for x in range(16):
            if not inside(x, y, top, bottom):
                continue
            edge = (x in (0, 15) or y in (top, bottom)
                    or not inside(x - 1, y, top, bottom) or not inside(x + 1, y, top, bottom)
                    or not inside(x, y - 1, top, bottom) or not inside(x, y + 1, top, bottom))
            if edge:
                col = OUTLINE
            elif y > face_bottom:
                col = LIP
            elif y == top + 1 or (x == 1 and y < face_bottom):
                col = EDGE[tone]
            else:
                col = FACE[tone]
            px((ox + x, oy + y), col)
    return top


def draw(frame):
    img = Image.new("RGBA", (80, 112), (0, 0, 0, 0))
    tone = "idle" if frame == "idle" else "hot"
    for i, name in enumerate(ORDER):
        ox, oy = (i % 5) * 16, (i // 5) * 16
        top = plate(img, ox, oy, frame)
        glyph = G[name]
        if not glyph:
            continue
        for gy, row in enumerate(glyph):
            for gx, ch in enumerate(row):
                if ch == "#":
                    img.putpixel((ox + 3 + gx, oy + 3 + top + gy), INK[tone])
    return img


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    for frame in ("idle", "hot", "press", "on"):
        draw(frame).save(out / f"iconbtn-{frame}.png")
    print(out)


if __name__ == "__main__":
    main()
