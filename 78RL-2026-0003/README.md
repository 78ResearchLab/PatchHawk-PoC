# 78RL-2026-0003

## 7-Zip: a split cabinet whose second volume declares no folders

| | |
|---|---|
| **Affected** | 7-Zip 26.02 |
| **Fixed in** | 26.03 |
| **Advisory** | None. `78RL-2026-0003` is a project-assigned identifier provided so the fix can be cited; the change does not appear in the 26.03 changelog |
| **Severity** | Not assigned by upstream |
| **Class** | CWE-476 NULL pointer dereference, reached through an unchecked array index. No write, and no code-execution primitive is shown |
| **Where** | `CPP/7zip/Archive/Cab/CabHandler.cpp`, in the folder-decompression loop |
| **Entry point** | `7zz x poc.cab` — extracting a split cabinet from the command line |

## At a glance

A cabinet file stores its compressed data in *folders*, and a file may continue
from one cabinet into the next. When 7-Zip 26.02 follows such a file across the
volume boundary it resets the folder index to zero and indexes the next
cabinet's folder array — checking only that the index is not negative.

A second cabinet that declares **zero folders** therefore causes an index into an
empty vector. 7-Zip's `CRecordVector` keeps a null backing pointer while empty,
so the read lands on the zero page.

The defect is in the decompression loop, not in the header parser: listing the
archive does not reach it. The proof of concept is a pair of cabinets totalling
**161 bytes**.

## Root cause

While decoding a folder that continues into the next cabinet, 26.02 checks only
the lower bound before indexing:

```cpp
        const CDatabaseEx &db2 = m_Database.Volumes[volIndex];
        if (locFolderIndex < 0)
          return E_FAIL;
        const CFolder &folder2 = db2.Folders[(unsigned)locFolderIndex];
```

and on the volume switch it resets that index to zero:

```cpp
          if (m_Database.Volumes.Size() > 1)
          {
            volIndex++;
            locFolderIndex = 0;
            bl = 0;
            continue;
          }
```

`CDatabase::Folders` is a `CRecordVector<CFolder>`, whose default state is a null
buffer (`CPP/Common/MyVector.h`):

```cpp
  CRecordVector(): _items(NULL), _size(0), _capacity(0) {}
```

and whose indexing operator is a bare `_items[index]`. Indexing an empty one
reads `folder2.DataStart` and `folder2.NumDataBlocks` through a null base
pointer.

Nothing in 26.02's parse path rejects a cabinet that declares no folders and no
files, so `Volumes[1].Folders` stays empty.

### Why this is the decompression path

The faulting line sits inside the loop that pulls compressed data blocks for the
folder, which runs only while the decoder still wants output:

```cpp
      for (UInt32 bl = 0; cabFolderOutStream->NeedMoreWrite();)
```

The values read out of bounds are exactly the ones used to locate the next
compressed block:

```cpp
        res = blockPackData.Read(db2.Stream, db2.ArcInfo.GetDataBlockReserveSize(), packSize, unpackSize);
```

This is why `7zz l` does not reproduce the issue while `7zz x` and `7zz t` do.

26.03 adds the missing upper bound:

```cpp
        if ((unsigned)locFolderIndex >= db2.Folders.Size())
        {
          res = S_FALSE;
          break;
        }
```

and also rejects a folderless cabinet that carries items at parse time:

```cpp
    const unsigned numFolders = db.Folders.Size();
    if (numFolders == 0 || item.GetFolderIndex(numFolders) >= (int)numFolders)
    {
      HeaderError = true;
      return S_FALSE;
    }
```

## How the proof of concept works

[`poc.cab`](poc.cab) and [`poc2.cab`](poc2.cab) are assembled from scratch by
[`make-poc-image.sh`](make-poc-image.sh). Both must sit in the same directory:
7-Zip follows the next-cabinet name stored inside the first.

1. **`poc.cab`** declares one folder and one file whose folder index is the
   special value `0xFFFE` (`kContinuedToNext`). `CItem::GetFolderIndex()` maps
   that to `numFolders - 1`, which is 0, so the item passes 26.02's
   upper-bound-only validation. The header sets the `NEXT_CABINET` flag and names
   `poc2.cab`.
2. **`poc2.cab`** declares **zero folders and zero files**. 26.02 accepts it,
   because the per-item folder check only runs when there are items.

Extraction reads the first cabinet's single data block, finds the file is not
complete, switches to the second cabinet, resets the folder index to 0, and
indexes an empty vector.

## How to reproduce

The reproduction runs entirely in Docker. Apart from the generated transcripts
in this directory, it does not build or install anything on the host.

From this directory, build both versions once:

```bash
docker build -t 7zip-poc:3 build/
```

The image downloads both releases from `7-zip.org`, verifies their SHA-256
checksums, and builds the Linux command-line tool with AddressSanitizer. The two
binaries are installed as `7zz-vulnerable` and `7zz-fixed`.

7-Zip ships a GNU makefile rather than a `configure` script. The build therefore
passes sanitizer flags through `MY_ARCH`, which reaches both the compiler and
linker. It also excludes hand-written assembly so every routine is instrumented.

Then run the comparison:

```bash
docker run --rm -v "$PWD:/poc" 7zip-poc:3
```

The container extracts `poc.cab` with each version and writes both transcripts to
`output/`. If the cabinets are missing, it first regenerates them with
`make-poc-image.sh`.

## Results

### 7-Zip 26.02

AddressSanitizer stops the extraction. The full transcript is in
[`output/vulnerable-26.02.txt`](output/vulnerable-26.02.txt); abridged here to
remove instruction addresses, build paths and the frames in between:

```
==11==ERROR: AddressSanitizer: SEGV on unknown address 0x000000000000
==11==The signal is caused by a READ memory access.
==11==Hint: address points to the zero page.
    #0 NArchive::NCab::CHandler::Extract(...) CabHandler.cpp:1092:11
    #1 DecompressArchive(...) Extract.cpp:243:23
    #2 Extract(...) Extract.cpp:550:5
    #3 Main2(int, char**) Main.cpp:1403:21
    #4 main MainAr.cpp:132:11

SUMMARY: AddressSanitizer: SEGV CabHandler.cpp:1092:11 in NArchive::NCab::CHandler::Extract(...)
```

### 7-Zip 26.03

The fixed version opens the same cabinet, lists the same item, and declines it
with an ordinary data error. The full transcript is in
[`output/fixed-26.03.txt`](output/fixed-26.03.txt):

```
Path = poc.cab
Type = Cab
Physical Size = 116
Total Physical Size = 161
Method = None
Blocks = 1
Volumes = 2
Volume Index = 0
ID = 4369

ERROR: Data Error : x.bin

Sub items Errors: 1
```

That 26.03 reaches the same state rather than rejecting the file earlier is what
shows the new bounds check is the thing doing the work.

## Impact and limitations

The read is through a null base pointer, so it is a deterministic crash rather
than a disclosure: there is no attacker-chosen offset and no adjacent heap data
involved. The proof of concept does not write memory or demonstrate control of
execution.

Reaching the defect requires extraction — `7zz l` completes normally on the same
input — and requires both cabinets to be present, which is the normal way split
cabinets are distributed.

## Author

Automatically generated by PatchHawk.
