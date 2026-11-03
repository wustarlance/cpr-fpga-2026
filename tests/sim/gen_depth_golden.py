#!/usr/bin/env python3
"""Build the grade-row fixtures from the text/layout contract."""
import argparse
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    fixture = HERE / 'fixtures'
    rows = json.loads((fixture / 'depth_labels_layout.json').read_text(encoding='utf-8'))
    ids = json.loads((REPO / 'project/assets/font/glyphs.json').read_text(encoding='utf-8'))['ids']
    assert [(r['grade'], r['adc']) for r in rows] == [(g, a) for g in range(4) for a in [False, True]]
    for language in ['ascii', 'chinese']:
        assert all(len(row[language]) == 14 for row in rows)
        values = [ord(c) if language == 'ascii' else ids[c] for row in rows for c in row[language]]
        text = ''.join(f'{value:02x}\n' for value in values)
        output = fixture / ('depth_labels_ascii.mem' if language == 'ascii' else 'depth_labels_zh.mem')
        if args.check:
            assert output.read_text(encoding='ascii') == text, output
        else:
            output.write_text(text, encoding='ascii', newline='\n')
    print('OK: eight grade rows per language match the layout contract')


if __name__ == '__main__':
    main()
