# 78RL-2026-0001

## 7-Zip: an ext image with more inodes than its bitmap can represent

| | |
|---|---|
| **Affected** | 7-Zip 26.01 |
| **Fixed in** | 26.02 |
| **Advisory** | None. `78RL-2026-0001` is a project-assigned identifier provided so the fix can be cited; the change does not appear in the 26.02 changelog |
| **Severity** | Not assigned by upstream |
| **Class** | CWE-125 out-of-bounds read. No write, and no code-execution primitive is shown |
| **Where** | `CPP/7zip/Archive/ExtHandler.cpp`, in the archive-open path |
| **Entry point** | `7zz l image.ext` — listing the archive from the command line |

## At a glance

7-Zip 26.01 trusts the inode count declared by an ext2/3/4 image without checking
whether the inode bitmap is large enough to represent it. A crafted image can
therefore make the archive reader continue past the end of its bitmap buffer.

The result is a heap out-of-bounds read in the normal archive-listing path. The
proof of concept triggers it with `7zz l image.ext`.

7-Zip 26.02 fixes the issue by rejecting inode counts larger than the bitmap's
capacity.

## Root cause

An ext2/3/4 filesystem tracks used inodes in a bitmap that is exactly one block
long. With a 1 KiB block, the bitmap can represent 1024 × 8 = **8192 inodes**.

7-Zip's ext reader allocates that one block and then walks it by inode number,
using a count taken from the superblock:

```cpp
UInt32 numNodes = _h.InodesPerGroup;
if (numNodes > _h.NumInodes) numNodes = _h.NumInodes;
...
nodesMap.Alloc(blockSize);
...
for (size_t n = 0; n < numNodes && globalNodeIndex < _h.NumInodes; n++, ...)
  if ((nodesMap[n >> 3] & (1u << (n & 7))) == 0)
```

Both values used by the loop come from the image. Version 26.01 only limits the
count to less than 2²⁴, and that check applies in just one case. It never checks
the count against the bitmap's actual capacity.

As a result, an image can declare 16,384 inodes while using a 1 KiB bitmap. Once
the loop reaches inode 8192, it reads byte 1024: the first byte beyond the
1024-byte allocation.

26.02 adds the missing comparison:

```cpp
const size_t blockSize = (size_t)1 << _h.BlockBits;
if (numNodes > blockSize * 8) return S_FALSE;
```

## How the proof of concept works

[`poc.ext`](poc.ext) starts as a working ext2 filesystem and changes only two
values. [`make-poc-image.sh`](make-poc-image.sh) reproduces the complete process:

1. `mke2fs` creates a valid, single-group ext2 image with 1 KiB blocks,
   128-byte inodes, and 8192 blocks. Because ext2 does not enable checksum
   features by default, the next step does not invalidate a CRC.
2. The script changes two 4-byte superblock fields from 2048 to **16384**:

   | Field | Offset in the superblock | New value |
   |---|---|---|
   | `s_inodes_count` | `0x00` | 16384 |
   | `s_inodes_per_group` | `0x28` | 16384 |

Setting both fields to the same value keeps the block-group count at one. This
ensures that 7-Zip reads group 0's real bitmap and then indexes beyond it. The
value also remains below the 2²⁴ limit enforced by 26.01.

The `.ext` suffix is not significant. 7-Zip detects archive types by content,
so the same bytes follow the same parser path under any filename.

## How to reproduce

The reproduction runs entirely in Docker. Apart from the generated transcripts
in this directory, it does not build or install anything on the host.

From this directory, build both versions once:

```bash
docker build -t 7zip-poc:1 build/
```

The image downloads both releases from `7-zip.org`, verifies their SHA-256
checksums, and builds the Linux command-line tool with AddressSanitizer. The two
binaries are installed as `7zz-vulnerable` and `7zz-fixed`.

7-Zip ships a GNU makefile rather than a `configure` script. The build therefore
passes sanitizer flags through `MY_ARCH`, which reaches both the compiler and
linker. It also excludes hand-written assembly so every routine is instrumented.

Then run the comparison:

```bash
docker run --rm -v "$PWD:/poc" 7zip-poc:1
```

The container lists `poc.ext` with each version and writes both transcripts to
`output/`. If the image is missing, it first regenerates it with
`make-poc-image.sh`.

## Results

### 7-Zip 26.01

AddressSanitizer stops the archive listing. The full transcript is in
[`output/vulnerable-26.01.txt`](output/vulnerable-26.01.txt); abridged here to
remove instruction addresses, build paths and the frames in between:

```
==332397==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x519000000e80
READ of size 1 at 0x519000000e80 thread T0
    #0 NArchive::NExt::CHandler::Open2(IInStream*) ExtHandler.cpp:1267:16
    #1 NArchive::NExt::CHandler::Open(...) ExtHandler.cpp:1571:13
    #2 CArc::OpenStream2(...) OpenArchive.cpp:1975:27
    #9 ListArchives(...) List.cpp:1191:30
    #10 Main2(int, char**) Main.cpp:1526:21
    #11 main MainAr.cpp:132:11

0x519000000e80 is located 0 bytes after 1024-byte region [0x519000000a80,0x519000000e80)
allocated by thread T0 here:
    #1 CBuffer<unsigned char>::Alloc(unsigned long) MyBuffer.h:69:18
```

The bottom of the stack—`main` → `Main2` → `ListArchives`—confirms that the
ordinary `l` command reaches the vulnerable code.

### 7-Zip 26.02

The fixed version rejects the same image before any out-of-bounds read. The full
transcript is in
[`output/fixed-26.02.txt`](output/fixed-26.02.txt):

```
Open ERROR: Cannot open the file as [Ext] archive


ERRORS:
Headers Error
```

This is the new `numNodes > blockSize * 8` check returning `S_FALSE`.

## Impact and limitations

This is a bounded read into adjacent heap memory. It can crash the process and
could, in principle, expose neighbouring bytes. The proof of concept does not
write memory or demonstrate control of execution.

The included image deliberately uses the smallest value that crosses the
boundary: 16,384 inodes for a 1 KiB bitmap. This makes AddressSanitizer stop on
the first byte beyond the allocation and keeps the report easy to interpret.

The defect is not limited to a one-byte over-read. A value of 65,536 inodes
passes 26.01's existing check while leaving the inode table allocatable. Without
a sanitizer stopping execution immediately, that value can drive reads
thousands of bytes beyond the 1024-byte buffer.

## Author

Automatically generated by PatchHawk.
