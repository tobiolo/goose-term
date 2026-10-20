#!/usr/bin/env python3
"""Write the conformance streams into a directory: one small file per feature,
each a byte stream a program could send to a terminal. tests/diff.py runs every
row over them and compares the dumps."""
import os
import random
import sys

E = '\x1b'
C = E + '['

def b(s):
    return s.encode('utf-8', 'surrogateescape') if isinstance(s, str) else s

cases = {}

def case(name, *parts):
    cases[name] = b''.join(b(p) for p in parts)

# Text, wrapping, control characters.
case('ascii', 'hello world\r\nsecond line\n  indented\rX')
case('wrap', 'x' * 200, '\r\n', 'y' * 174, 'z')
case('nowrap', C + '?7l', 'a' * 200, '\r\n', C + '?7h', 'b' * 180)
case('tabs', 'a\tb\tc\r\n', '\t' * 30, 'end', C + '3g', '\r\n\tq', E + 'H', C + '0g', C + '2I', 'w', C + '3Z', 'v')
case('backspace', 'abc\b\bX', 'y' * 174, '\b\bZ')
case('lf_scroll', ''.join(f'line {i}\n' for i in range(120)))
case('crlf_scroll', ''.join(f'line {i}\r\n' for i in range(15000)))
case('controls', 'a\x00b\x07c\x0bd\x0ce\x7ff\x05g\r\n')

# Cursor motion.
case('cup', C + '10;20Hx', C + 'Hy', C + '5;5f', 'z', C + '999;999H', 'w', C + '0;0H', 'v')
case('relative', C + '20;80H', C + '3A', 'a', C + '2B', 'b', C + '10C', 'c', C + '4D', 'd',
     C + '2E', 'e', C + '3F', 'f', C + '40G', 'g', C + '7d', 'h', C + '5`', 'i', C + '3a', 'j', C + '2e', 'k')
case('save_restore', C + '5;5H', C + '31m', E + '7', C + '20;20H', C + '0m', 'x', E + '8', 'y', C + 's', C + '30;3H', C + 'u', 'z')
case('origin', C + '5;20r', C + '?6h', C + 'Hx', C + '3;3Hy', C + '99;1Hz', C + '2A', 'w', C + '?6l', C + 'Hv', C + 'r')

# Erasing (with background colors, to see BCE).
fill = ''.join(f'{i:03d}' + 'abcdefghij' * 17 + '\r\n' for i in range(38))
case('ed0', fill, C + '44m', C + '10;50H', C + 'J')
case('ed1', fill, C + '42m', C + '10;50H', C + '1J')
case('ed1_row1', fill, C + '42m', C + '2;50H', C + '1J')
case('ed2_primary', 'some text\r\nmore\r\n', C + '41m', C + '2J', 'after')
case('ed2_full', fill, 'last line', C + '2J', 'after')
case('ed3', ''.join(f'h{i}\n' for i in range(100)), C + '3J', 'x')
case('el', fill, C + '45m', C + '3;10H', C + 'K', C + '4;10H', C + '1K', C + '5;10H', C + '2K')
case('el_pending', 'q' * 174, C + 'K', C + '43m', 'r')
case('ech_dch_ich', fill, C + '46m', C + '3;10H', C + '5X', C + '4;10H', C + '5P', C + '5;10H', C + '5@',
     C + '6;170H', C + '9P', C + '7;5H', C + '999P', C + '8;1H', C + '999@')

# Lines and scrolling regions.
case('il_dl', fill, C + '5;1H', C + '3L', C + '20;1H', C + '2M', C + '1;1H', C + '2M')
case('region_scroll', fill, C + '5;15r', C + '15;1H', '\n\n\nabc', C + '5;1H', E + 'M', E + 'M', 'def', C + 'r')
case('region_top', fill, C + '1;20r', C + '20;1H', ''.join(f'\nr{i}' for i in range(30)), C + 'r')
case('region_bottom_alt', C + '?1049h', C + '1;38r', ''.join(f'y{i}\n' for i in range(100)))
case('su_sd', fill, C + '3S', C + '2T', C + '10;20r', C + '4S', C + '6T', C + 'r', C + '99S')
case('ri_top', fill, C + 'H', E + 'M' * 5, 'x')
case('ind_nel', 'a', E + 'D', 'b', E + 'E', 'c', C + '39;1H', E + 'D' * 3, 'd')
case('decstbm_bad', C + '20;10r', 'x', C + '30;99r', '\n' * 20, 'y', C + '0;0r', 'z')

# Attributes.
sgr = ['0', '1', '2', '3', '4', '4:3', '4:0', '5', '7', '8', '9', '21', '22', '23', '24', '27', '28', '29',
       '31', '39', '42', '49', '93', '104', '38;5;196', '48;5;21', '38;2;1;2;3', '48;2;250;128;0',
       '38:2::10:20:30', '38:2:10:20:30', '48:5:99', '58;5;3', '59', '38;5;300', '38;2;1;2', '1;31;42']
case('sgr', ''.join(f'{C}{p}mX{C}0m ' for p in sgr), '\r\n',
     ''.join(f'{C}{p}mY' for p in sgr))
case('sgr_blank', C + '41;32;1m', '   ', C + '7m', '  ', C + '4m', '  ', C + '0m', C + 'K')

# Modes and screens.
case('alt', 'primary text\r\n' * 3, C + '?1049h', 'alt text', C + '31m', C + '5;5Hz', C + '?1049l', 'back')
case('alt_cursor', C + '10;10H', C + '32m', 'p', C + '?1049h', 'q', C + '20;20H', C + '?1049l', 'r')
case('insert', 'abcdefgh', C + '4h', C + '1;3H', 'XYZ', C + '4l', 'w')
case('decaln', E + '#8', C + '5;5H', 'x')
case('ris', 'stuff', C + '31m', C + '5;10r', E + 'c', 'fresh')
case('deccolm', 'abc', C + '?3h', 'x', C + '?3l', 'y')

# Character sets.
case('dec_graphics', E + '(0', 'lqqqqk\r\nx    x\r\nmqqqqj', E + '(B', ' ok ', E + ')0', '\x0eqqq\x0f qqq')

# Unicode.
case('wide', '日本語テキスト ', '中' * 100, '\r\n', 'a' * 173, '字', 'b')
case('wide_overwrite', '日本語', C + '1;2H', 'x', C + '1;5H', 'y', '\r\n', '中文', C + '2;1H', 'abcd')
case('wide_nowrap', C + '?7l', 'a' * 173, '字字', C + '?7h')
case('combining', 'é ạ̈ ', '中́', ' x', C + '1;1H', '̀', 'q' * 173, '́')
case('emoji', '🙏 👍🏽 🇩🇪 ❤️ ok')
case('rep', 'ab', C + '5b', '\r\n', '中', C + '3b', '\r\n', C + '2b')

# Malformed UTF-8 and C1.
case('bad_utf8', b'a\xffb\xc3c\xe2\x82d\xe2\x82\xac\xf0\x9f\x98e\xed\xa0\x80f\xc0\xafg', b'\xc2\x85h\x85i\x9bj', b'\xe2\x82' + b'\x1b[31mk')

# Strings the parser skips.
case('strings', E + ']0;window title\x07', 'a', E + ']2;other' + E + '\\', 'b', E + 'P1$r q' + E + '\\', 'c',
     E + '_apc payload' + E + '\\', 'd', E + ']52;c;ZGF0YQ==\x07', 'e', E + 'Xsos' + E + '\\', 'f')
case('aborted', C + '31', '\x18', 'a', C + '1;2', '\x1a', 'b', C + '5', E + '[32mc', E + 'P12', '\x18d')
case('csi_odd', C + '?25l', C + '>4;1m', C + '=1u', C + '>1u', C + '<u', C + ' q', C + '2 q', C + '?2026h', 'x',
     C + '?2026l', C + '!p', C + '1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;21;22;23;24;25;26;27;28;29;30;31;32;33m', 'y',
     C + '5n', C + '6n', C + 'c', C + '>c', C + '18t', C + '?1h' + E + '=', 'z', C + '?1l' + E + '>')

# Random streams, from a fixed seed: every kind of sequence above, in any order.
def random_stream(seed, n):
    r = random.Random(seed)
    words = ['hello', 'world', '日本', 'é', 'x' * 40, '\t', '\r\n', '\n', '\b', 'q', '🙏', 'á']
    out = []
    for _ in range(n):
        k = r.random()
        if k < 0.35:
            out.append(r.choice(words))
        elif k < 0.5:
            out.append(f'{C}{r.randint(0, 45)};{r.randint(0, 180)}H')
        elif k < 0.65:
            out.append(C + r.choice(sgr) + 'm')
        elif k < 0.8:
            out.append(C + str(r.randint(0, 6)) + r.choice('ABCDEFGJKLMPSTXZ@bdeg'))
        elif k < 0.85:
            out.append(f'{C}{r.randint(0, 20)};{r.randint(0, 45)}r')
        elif k < 0.9:
            out.append(r.choice([C + '?1049h', C + '?1049l', C + '?7l', C + '?7h', C + '?6h', C + '?6l',
                                 C + '4h', C + '4l', E + '7', E + '8', E + 'M', E + 'D', E + 'E', E + '(0', E + '(B']))
        else:
            out.append(r.choice(['abc', 'z' * 90, '\x0e', '\x0f', E + 'H', C + '3J', C + '2J']))
    return ''.join(out)

for seed in range(20):
    case(f'random{seed:02d}', random_stream(seed, 3000))

if __name__ == '__main__':
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    for name, data in cases.items():
        with open(os.path.join(d, name + '.bin'), 'wb') as f:
            f.write(data)
    print(f'{len(cases)} cases in {d}')
