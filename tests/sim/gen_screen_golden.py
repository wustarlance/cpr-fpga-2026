#!/usr/bin/env python3
"""Regenerate tests/sim/fixtures/chinese_screen_cells.mem from the layout contract.

The fixture is the *independent* expectation table used by tb_chinese_overlay:
9600 entries = 8 screens (4 states x 2 ADC variants) x 1200 cells (40 x 30),
each entry {color[23:0], glyph_id[7:0]}. It is built only from
chinese_screen_layout.json (the layout contract) and the generated glyph IDs in
project/assets/font/glyphs.json -- never from cpr_text_zh.v, so a layout change
must be described in the JSON first and then rendered here.

  python tests/sim/gen_screen_golden.py            # rewrite the .mem
  python tests/sim/gen_screen_golden.py --check    # verify it still matches
"""
import argparse
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
LAYOUT = HERE / "fixtures/chinese_screen_layout.json"
GLYPHS = REPO / "project/assets/font/glyphs.json"
OUT = HERE / "fixtures/chinese_screen_cells.mem"

COLS, ROWS = 40, 30


def build():
    layout = json.loads(LAYOUT.read_text(encoding="utf-8"))
    ids = json.loads(GLYPHS.read_text(encoding="utf-8"))["ids"]
    cells = [[0xFFFFFF00] * (COLS * ROWS) for _ in layout]   # 空白格：白色 + 空格字形
    for screen, spec in enumerate(layout):
        for entry in spec["entries"]:
            color, col, row = int(entry["color"], 16), entry["column"], entry["row"]
            for i, ch in enumerate(entry["text"]):
                if ch not in ids:
                    raise SystemExit("layout uses a glyph that the font does not have: %r" % ch)
                index = row * COLS + col + i
                if not 0 <= col + i < COLS:
                    raise SystemExit("entry crosses the 40-column boundary: %r" % entry)
                cells[screen][index] = (color << 8) | ids[ch]
    return ["%08x" % value for screen in cells for value in screen]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只比对，不写文件")
    args = ap.parse_args()
    lines = build()
    if args.check:
        current = [l.strip() for l in OUT.read_text(encoding="ascii").splitlines() if l.strip()]
        if current == lines:
            print("OK: %d entries match the layout contract" % len(lines))
            return 0
        diff = next((i for i, (a, b) in enumerate(zip(current, lines)) if a != b), None)
        print("MISMATCH at entry %s (file %d entries, contract %d)" % (diff, len(current), len(lines)))
        return 1
    OUT.write_text("\n".join(lines) + "\n", encoding="ascii")
    print("wrote %s (%d entries)" % (OUT.relative_to(REPO), len(lines)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
