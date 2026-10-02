#!/usr/bin/env python3
"""Writes krc.js: KuGou-style KRC test payloads (made-up lyrics, no real song).

KRC as KuGou sends it: base64 of "krc1" + (zlib stream XOR a fixed 16-byte
key). `small` is a normal two-line song; `bomb` inflates to 2 MiB from about
2 KB, the shape of a decompression bomb, which the widget must refuse.
Run it again only to change the payloads; the output is checked in.
"""
import base64, zlib, os
KEY = bytes([0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69])

def krc(raw: bytes) -> str:
    z = zlib.compress(raw, 9)
    return base64.b64encode(b"krc1" + bytes(b ^ KEY[i % 16] for i, b in enumerate(z))).decode()

small = ("[ti:Test Song]\n"
         "[1000,1600]<0,400,0>Hello <400,400,0>there <800,800,0>world\n"
         "[3000,1200]<0,600,0>Second <600,600,0>line\n"
         "[4500,1500]<0,500,0>Third <500,500,0>line <1000,500,0>here\n").encode()
bomb = b"[1000,1000]<0,500,0>" + b"a" * (2 * 1024 * 1024)
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "krc.js")
with open(out, "w") as f:
    f.write(".pragma library\n// Made by mkkrc.py. Test payloads only.\n")
    f.write("var small = \"%s\"\n" % krc(small))
    f.write("var bomb = \"%s\"\n" % krc(bomb))
    f.write("var bombSize = %d\n" % len(bomb))
