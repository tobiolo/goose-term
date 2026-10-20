#!/usr/bin/env python3
"""Write gui/box.goose: how gterm draws U+2500-U+257F itself, from the
characters' Unicode names, so box lines join from cell to cell.

Each character is four arms (up, right, down, left), each 0 (none), 1
(light), 2 (heavy) or 3 (double), packed as up | right << 2 | down << 4 |
left << 6. Dashed lines are drawn solid, arcs as corners. 0 means the font
draws it (the diagonals).

  python3 -I gui/gen_box.py > gui/box.goose
"""
import unicodedata

WEIGHT = {'LIGHT': 1, 'HEAVY': 2, 'DOUBLE': 3}
DIRS = ['UP', 'RIGHT', 'DOWN', 'LEFT']


def arms(cp):
    name = unicodedata.name(chr(cp)).replace('BOX DRAWINGS ', '')
    if 'DIAGONAL' in name:
        return None
    words = name.split()
    if 'DASH' in words:
        w = WEIGHT[words[0]]
        return [0, w, 0, w] if 'HORIZONTAL' in words else [w, 0, w, 0]
    name = name.replace('ARC ', '').replace('SINGLE', 'LIGHT')
    # "LIGHT DOWN AND RIGHT", "DOWN LIGHT AND RIGHT HEAVY",
    # "UP HEAVY AND DOWN HORIZONTAL LIGHT", "LIGHT LEFT AND HEAVY RIGHT": a
    # weight before the directions holds for later parts that name none, and
    # a part without one takes the next part's.
    parts = []
    for p in name.split(' AND '):
        dirs, w = [], None
        for word in p.split():
            if word in WEIGHT:
                w = WEIGHT[word]
            elif word == 'HORIZONTAL':
                dirs += ['RIGHT', 'LEFT']
            elif word == 'VERTICAL':
                dirs += ['UP', 'DOWN']
            elif word in DIRS:
                dirs.append(word)
            else:
                raise ValueError(f'{cp:04X} {name}: {word}')
        parts.append([dirs, w])
    lead = next((WEIGHT[w] for w in WEIGHT if name.startswith(w + ' ')), None)
    for i, part in enumerate(parts):
        if part[1] is None:
            part[1] = lead if lead is not None else next(w for _, w in parts[i + 1:] if w)
        lead = part[1] if lead is not None else None
    out = [0, 0, 0, 0]
    for dirs, w in parts:
        for d in dirs:
            out[DIRS.index(d)] = w
    return out


def main():
    vals = []
    for cp in range(0x2500, 0x2580):
        a = arms(cp)
        vals.append(0 if a is None else a[0] | a[1] << 2 | a[2] << 4 | a[3] << 6)
    print('// Written by gui/gen_box.py from the Unicode names of U+2500-U+257F: each box')
    print('// drawing character\'s arms, up | right << 2 | down << 4 | left << 6, each')
    print('// 0 none, 1 light, 2 heavy, 3 double; 0 for one the font draws.')
    print()
    print('namespace box;')
    print()
    print('let ARMS: u8[128] = [')
    for i in range(0, 128, 16):
        print('    ' + ', '.join(f'{v:3d}' for v in vals[i:i + 16]) + (',' if i < 112 else ''))
    print('];')


main()
