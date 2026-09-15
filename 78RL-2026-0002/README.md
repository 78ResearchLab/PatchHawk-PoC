# 78RL-2026-0002

## 7-Zip: a split WIM whose stream table points at a volume that was never opened

| | |
|---|---|
| **Affected** | 7-Zip 26.02 |
| **Fixed in** | 26.03 |
| **Advisory** | None. `78RL-2026-0002` is a project-assigned identifier provided so the fix can be cited; the change does not appear in the 26.03 changelog |
| **Severity** | Not assigned by upstream |
| **Class** | CWE-125 out-of-bounds read leading to CWE-822 untrusted pointer dereference. No write, and no code-execution primitive is shown |
| **Where** | `CPP/7zip/Archive/Wim/WimHandler.cpp` and `WimIn.cpp`, in the extraction path |
| **Entry point** | `7zz x poc.swm` — extracting a split archive from the command line |

## At a glance

A split WIM archive (`.swm`) carries a table of stream descriptors, and each
descriptor names the volume that holds its data. 7-Zip 26.02 uses that volume
number as an array index without checking it against the number of volumes it
actually opened.

The array is a vector of *pointers*, so an out-of-range index does not merely
read adjacent data: it loads a pointer from beyond the allocation and
dereferences it. The resulting `CVolume` is then handed straight to the
decompressor.

The proof of concept is a pair of volumes totalling 634 bytes. Extracting them
with 26.02 stops under AddressSanitizer; 26.03 reports an ordinary error.

## Root cause

A stream descriptor's volume number is a 16-bit field read from the archive
(`CPP/7zip/Archive/Wim/WimIn.cpp`):

```cpp
    s.PartNumber = Get16(p + 24);
```

`_volumes` is a `CObjectVector<CVolume>`, whose indexing operator resolves an
element by dereferencing a pointer stored in a separate array
(`CPP/Common/MyVector.h`):

```cpp
  const T& operator[](unsigned index) const { return *((T *)_v[index]); }
```

26.02 indexes it with the archive-supplied number in three places. In
`WimIn.cpp` the necessary check was present in the source but commented out:

```cpp
      /*
      if (si.PartNumber >= volumes.Size())
        continue;
      */
      const CVolume &vol = volumes[si.PartNumber];
```

### Why a single volume is not enough

When the stream table is parsed, descriptors whose volume number disagrees with
the volume's own header are discarded before they can be stored:

```cpp
    if (s.PartNumber != h.PartNumber)
      continue;
```

and `CHandler::Open` grows `_volumes` to cover the header's own number:

```cpp
      while (_volumes.Size() <= header.PartNumber)
        _volumes.AddNew();
```

So a lone file cannot produce an out-of-range index. The gap is in the order of
those two steps across *multiple* volumes. `_db.Open()` appends a volume's
descriptors to the **shared** `_db.DataStreams` before `_volumes` is grown, and a
secondary volume that fails afterwards is simply skipped:

```cpp
      if (res != S_OK)
      {
        if (i != 1 && res == S_FALSE)
          continue;
        return res;
      }
```

That leaves descriptors in `DataStreams` whose volume number is greater than or
equal to `_volumes.Size()`.

### Why extraction is the trigger

Two different sites index `_volumes` with the same unchecked number. The one the
proof of concept reaches first is the property query that extraction performs
while preparing hard links — frame #4 of the report below is literally
`DecompressArchive`. The second site supplies the stream and header handed to
the unpacker, a few steps further along the same command:

```cpp
      const CVolume &vol = _volumes[si.PartNumber];
      const bool needDigest = !si.IsEmptyHash() && !_disable_Sha1Check;
      const HRESULT res = unpacker.Unpack(vol.Stream, si.Resource, vol.Header, &_db,
```

Both are on the `x` path; 26.03 guards each of them separately.

26.03 adds the missing bound at each site, for example:

```cpp
    if (si.PartNumber >= _volumes.Size())
      opRes = NExtract::NOperationResult::kUnavailable;
```

restores the commented-out check in `WimIn.cpp`, and adds a whole-database
validator, `CDatabase::Check_PartNumber_in_Items()`.

## How the proof of concept works

[`poc.swm`](poc.swm) and [`poc2.swm`](poc2.swm) are built from scratch by
[`make-poc-image.sh`](make-poc-image.sh); no reference archive is needed. Both
files must sit in the same directory, because 7-Zip derives the second volume's
name from the first.

1. **`poc.swm`** is a valid volume 1 with an empty stream table. Opening it grows
   `_volumes` to two entries, indices 0 and 1.
2. **`poc2.swm`** declares `PartNumber = 2` and contributes one data-stream
   descriptor that also claims volume 2. Its header carries a non-empty
   `MetadataResource`, which makes `CDatabase::Open()` finish with
   `if (needBootMetadata) return S_FALSE;` — *after* the stream table has already
   been appended.

Volume 2 is therefore skipped by the `continue` shown above, `_volumes` never
grows to three entries, and the orphaned descriptor asks for `_volumes[2]` on a
two-element vector.

The `.swm` suffix is what makes 7-Zip look for the second volume; the contents
are detected by signature.

## How to reproduce

The reproduction runs entirely in Docker. Apart from the generated transcripts
in this directory, it does not build or install anything on the host.

From this directory, build both versions once:

```bash
docker build -t 7zip-poc:2 build/
```

The image downloads both releases from `7-zip.org`, verifies their SHA-256
checksums, and builds the Linux command-line tool with AddressSanitizer. The two
binaries are installed as `7zz-vulnerable` and `7zz-fixed`.

7-Zip ships a GNU makefile rather than a `configure` script. The build therefore
passes sanitizer flags through `MY_ARCH`, which reaches both the compiler and
linker. It also excludes hand-written assembly so every routine is instrumented.

Then run the comparison:

```bash
docker run --rm -v "$PWD:/poc" 7zip-poc:2
```

The container extracts `poc.swm` with each version and writes both transcripts to
`output/`. If the volumes are missing, it first regenerates them with
`make-poc-image.sh`.

## Results

### 7-Zip 26.02

AddressSanitizer stops the extraction. The full transcript is in
[`output/vulnerable-26.02.txt`](output/vulnerable-26.02.txt); abridged here to
remove instruction addresses, build paths and the frames in between:

```
==11==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x502000011ce0
READ of size 8 at 0x502000011ce0 thread T0
    #0 CObjectVector<NArchive::NWim::CVolume>::operator[](int) MyVector.h:519:56
    #1 NArchive::NWim::CHandler::GetProperty(...) WimHandler.cpp:399:14
    #2 Archive_Get_HardLinkNode(...) ArchiveExtractCallback.cpp:216:5
    #3 CArchiveExtractCallback::PrepareHardLinks(...) ArchiveExtractCallback.cpp:255:7
    #4 DecompressArchive(...) Extract.cpp:219:5
    #5 Extract(...) Extract.cpp:550:5
    #6 Main2(int, char**) Main.cpp:1403:21
    #7 main MainAr.cpp:132:11

0x502000011ce0 is located 0 bytes after 16-byte region [0x502000011cd0,0x502000011ce0)
allocated by thread T0 here:
    #3 CObjectVector<NArchive::NWim::CVolume>::AddNew() MyVector.h:555:8
    #4 NArchive::NWim::CHandler::Open(...) WimHandler.cpp:942:18
```

### 7-Zip 26.03

The fixed version handles the same archive and reports an ordinary error. The
full transcript is in [`output/fixed-26.03.txt`](output/fixed-26.03.txt):

```
ERRORS:
Headers Error

--
Path = poc.swm
Type = wim
ERRORS:
Headers Error
Multivolume = +
Volume = 1
Volumes = 1

ERROR: Unavailable data : [DELETED]/0
```

Two separate signals in that transcript are the new code: `Headers Error` is the
`_error_in_PartNumber` flag raised by `Check_PartNumber_in_Items()`, and
`Unavailable data` is the `kUnavailable` result returned by the new bound in
`Extract`. 26.03 does not reject the file outright — it reaches the same parser
state and declines the item.

## Impact and limitations

The index is a 16-bit field, so it can select a pointer up to roughly half a
megabyte beyond a small allocation. What is dereferenced is whatever that memory
happens to hold, which makes the outcome a crash in practice rather than a
controlled read. The proof of concept does not write memory or demonstrate
control of execution.

Reaching the defect requires the multi-volume path: a single `.wim` file cannot
trigger it, because mismatched descriptors are discarded before they are stored.
Both volumes must be present together, which is the normal way split archives
are distributed.

## Author

Automatically generated by PatchHawk.
