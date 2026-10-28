# 78RL-2026-0010

## 7-Zip: a short NTFS `$VOLUME_INFORMATION` attribute is read past its buffer while listing

| | |
|---|---|
| **Affected** | 7-Zip 26.04, for the tested NTFS image |
| **Fixed in** | 7-Zip 26.05 skips the short attribute before reading it |
| **Advisory** | No matching CVE or GHSA was confirmed in the checked advisory and CVE sources as of 2026-10-28; the 26.05 release notes say only "Some bugs and vulnerabilities were fixed". `78RL-2026-0010` is a project-assigned reproducer ID, not an advisory |
| **Severity** | Not assigned by upstream |
| **Class** | CWE-125 out-of-bounds read: two 1-byte reads immediately past an exact-size 8-byte heap buffer; no write primitive is shown |
| **Where** | `CPP/7zip/Archive/NtfsHandler.cpp`, `CMftRec::ParseRec()`, `$VOLUME_INFORMATION` branch |
| **Entry point** | `7zz l crafted.ntfs` — listing the archive from the command line |

## At a glance

The checked-in [64 KiB NTFS image](input/poc.ntfs) has a resident `$VOLUME_INFORMATION` attribute with an 8-byte payload. The real NTFS volume-info structure is 12 bytes: version major and minor sit at offsets 8 and 9. While listing, 7-Zip 26.04 copies the payload into an exact-size heap buffer and then reads those version bytes without checking the payload length.

On the ASan build of 26.04 the listing stops with a heap-buffer-overflow read at `NtfsHandler.cpp:1463`, exit 1. On an ordinary 26.04 build the listing completes and prints the two over-read bytes as the volume version (`File System = NTFS 0.0`). 26.05 skips the short payload and prints no version, exit 0.

The defect exists in exactly one release. Releases 21.07 through 26.03 parsed volume info through a guarded `CVolInfo::Parse`; the 26.04 attribute-handling rewrite inlined the read and dropped the length check, and 26.05 restored it.

## Root cause

The MFT `$Volume` record (record index 3) is parsed during archive open. In 26.04, `CMftRec::ParseRec()` dispatches its attributes like this:

```cpp
if (volInfo)
{
  if (type == ATTR_TYPE_VOLUME_NAME && volInfo->VolName.IsEmpty())
    GetString(attr.Data, (unsigned)attr.Data.Size() / 2, volInfo->VolName);
  else if (type == ATTR_TYPE_VOLUME_INFO /* && volInfo->FsVerMajor < 0 */)
  {
    volInfo->FsVerMajor = attr.Data[8];
    volInfo->FsVerMinor = attr.Data[9];
```

`attr.Data` holds the resident attribute payload in an exact-size heap buffer. `CAttr::ParseAttr()` validates that the declared payload fits inside the MFT record, but nothing requires a `$VOLUME_INFORMATION` payload to carry the full 12-byte structure. With an 8-byte payload, `attr.Data[8]` and `attr.Data[9]` read one and two bytes past the allocation. The volume-name branch above stays in bounds: `GetString()` receives `attr.Data.Size() / 2`, four UTF-16 units for this image's 8-byte name payload.

The parsed version reaches the listing through the `kpidFileSystem` archive property:

```cpp
case kpidFileSystem:
{
  char buf[32];
  char *s = MyStpCpy(buf, "NTFS");
  if (VolumeInfo.FsVerMajor >= 0)
  {
    *s++ = ' ';  s = ConvertUInt32ToString((UInt32)(unsigned)VolumeInfo.FsVerMajor, s);
    *s++ = '.';      ConvertUInt32ToString(VolumeInfo.FsVerMinor, s);
  }
```

A byte read out of bounds is always in the range 0 to 255, so the over-read bytes always turn the property into a version-shaped `NTFS <major>.<minor>` string.

### The fix

26.05 restores the length check and additionally ignores non-resident volume-info attributes ([26.05 `NtfsHandler.cpp`, lines 1459-1465](https://github.com/ip7z/7zip/blob/b88c6bc09339de32f7d18bbab900686b244f42ba/CPP/7zip/Archive/NtfsHandler.cpp#L1459-L1465)):

```cpp
if (volInfo && attr.NonResident == 0)
{
  if (type == ATTR_TYPE_VOLUME_NAME && volInfo->VolName.IsEmpty())
    GetString(attr.Data, (unsigned)attr.Data.Size() / 2, volInfo->VolName);
  else if (type == ATTR_TYPE_VOLUME_INFO && attr.Data.Size() >= 12 /* && volInfo->FsVerMajor < 0 */)
  {
    volInfo->FsVerMajor = attr.Data[8];
    volInfo->FsVerMinor = attr.Data[9];
```

This blocks exactly the input that over-reads: a resident `$VOLUME_INFORMATION` shorter than 12 bytes. A short payload is now skipped silently; the archive still opens and no version is printed. Sibling residency checks for `$FILE_NAME` and `$STANDARD_INFORMATION` shipped in the same change; this case isolates the volume-info read, the only one with an out-of-bounds access.

## How the proof of concept works

[`make-poc.py`](make-poc.py) builds both checked-in images with Python's standard library: a valid boot sector, four in-use MFT records, and in record 3 a resident `$VOLUME_NAME` ("PoC") plus the resident `$VOLUME_INFORMATION`. The [trigger](input/poc.ntfs) declares an 8-byte payload; the [control](input/control.ntfs) is identical except its attribute carries the full 12-byte payload, version 3.1. Every runner regenerates its input inside Docker and compares it byte-for-byte with the checked-in file before invoking `7zz`.

The command is a plain `7zz l` on a local file — the ordinary listing a user runs on an untrusted archive. No harness touches the handler.

- [`run-original.sh`](run-original.sh) lists the trigger with the ASan builds of 26.04 and 26.05.
- [`run-control.sh`](run-control.sh) lists the 12-byte control with both ASan builds.
- [`run-ordinary.sh`](run-ordinary.sh) lists the trigger with ordinary, unsanitized builds of both releases.
- [`run.sh`](run.sh) verifies the input hashes, builds the image, and invokes all three.

## Which versions are affected

These are Docker runs of exact release archives, not a claim about every earlier version or distribution backport.

| Release and build | Input | Observed result | Evidence |
|---|---|---|---|
| 26.04, ASan | 8-byte volume info | Heap-buffer-overflow read at `NtfsHandler.cpp:1463`, exit 1 | [Log](output/original-26.04.txt) |
| 26.04, ordinary | 8-byte volume info | Over-read bytes printed as `NTFS 0.0`, exit 0 | [Log](output/ordinary-26.04.txt) |
| 26.05, ASan | 8-byte volume info | Clean listing, no version printed, exit 0 | [Log](output/original-26.05.txt) |
| 26.05, ordinary | 8-byte volume info | No version printed, exit 0 | [Log](output/ordinary-26.05.txt) |
| 26.04 and 26.05, ASan | 12-byte control | Both print `NTFS 3.1`, exit 0 | [Pre](output/control-26.04.txt), [post](output/control-26.05.txt) |

Source inspection only, not executed: the tagged `NtfsHandler.cpp` of 21.07, 22.01, 24.09, 25.01, 26.00, 26.01, 26.02, and 26.03 parses volume info through `CVolInfo::Parse`, which rejects `size < 12` ([25.01 example](https://github.com/ip7z/7zip/blob/25.01/CPP/7zip/Archive/NtfsHandler.cpp#L394-L399)). The unguarded branch is a regression introduced by 26.04's attribute-handling rewrite and exists in that release alone.

## How to reproduce

From this directory, with Docker available and the host's `rg` and
`sha256sum` commands available:

```bash
./run.sh
```

The [Dockerfile](build/Dockerfile) downloads both official source archives during the image build and verifies their SHA-256 hashes before extraction; a missing or changed archive stops the build. 7-Zip publishes no source checksums, so the values below pin the downloaded bytes (the 26.04 archive is byte-identical on 7-zip.org and the GitHub release; 26.05's source archive is only published on GitHub). Docker needs network access during the build:

| Official source archive | SHA-256 | Resolved upstream tag |
|---|---|---|
| [7z2604-src.tar.xz](https://7-zip.org/a/7z2604-src.tar.xz) | `9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6` | [`26.04`](https://github.com/ip7z/7zip/releases/tag/26.04), `9128b80e3a471108678e2b3ec3c985861c8d7b0f` |
| [7z2605-src.tar.xz](https://github.com/ip7z/7zip/releases/download/26.05/7z2605-src.tar.xz) | `0b6080b8c3e7a579161d2d495224c0e51c467576cb4c7048b0ab485ef44cc22e` | [`26.05`](https://github.com/ip7z/7zip/releases/tag/26.05), `b88c6bc09339de32f7d18bbab900686b244f42ba` |

Each release is built as the standard `Bundles/Alone2` console tool twice: an ASan build (`clang`, `-fsanitize=address -g -fno-omit-frame-pointer`, flags passed through the makefile's `MY_ARCH`) and an ordinary `g++` build. The four binaries install as `7zz-vulnerable-asan`, `7zz-fixed-asan`, `7zz-vulnerable`, and `7zz-fixed`. Container runs use no network, a read-only root and case mount, disabled core dumps, a 20-second time limit, and bounded memory, CPU, and process counts. The runners assert the release banner, generator match, exit status, sanitizer diagnosis or absence, and the printed volume-version lines; they stop at the first mismatch. The runner writes only target execution evidence under [`output/`](output/); the Docker image is removed after the run. See the [asserted summary](output/reproduction.txt).

## Results

### 7-Zip 26.04: listing the trigger

The [ASan log](output/original-26.04.txt) records the release banner, a regenerated-payload match, and exit 1. Abridged here to shorten build paths and argument lists:

```
ERROR: AddressSanitizer: heap-buffer-overflow on address 0x5020000117f8
READ of size 1 at 0x5020000117f8 thread T0
    #0 ... in NArchive::Ntfs::CMftRec::ParseRec(...) .../Archive/NtfsHandler.cpp:1463:35
    #1 ... in NArchive::Ntfs::CDatabase::Open() .../Archive/NtfsHandler.cpp:1964:16

0x5020000117f8 is located 0 bytes after 8-byte region [0x5020000117f0,0x5020000117f8)
```

The 8-byte region is the crafted `$VOLUME_INFORMATION` payload; the read is the unguarded version field. The [ordinary-build log](output/ordinary-26.04.txt) shows the same listing without a sanitizer: exit 0 with `File System = NTFS 0.0` — the two bytes past the payload parsed as the volume version. Their values come from heap memory adjacent to the buffer, so only the version-shaped output is deterministic, not the digits.

### 7-Zip 26.05: listing the trigger

The [ASan log](output/original-26.05.txt) and the [ordinary log](output/ordinary-26.05.txt) both record exit 0, `Label = PoC`, and `File System = NTFS` with no version — the short payload is skipped. This is a guarded parse, not a rejection of the image.

### The 12-byte control

The [26.04](output/control-26.04.txt) and [26.05](output/control-26.05.txt) control logs both record `File System = NTFS 3.1` and exit 0, with no sanitizer finding on either release. The 26.05 change therefore blocks short payloads only; valid volume information still parses, and the 26.04 defect is exactly the missing length check.

## Impact and limitations

The demonstrated effect is a 2-byte out-of-bounds read of heap memory adjacent to a small attribute buffer, reached by listing a crafted NTFS image. On ordinary builds the over-read bytes are rendered as decimal version digits in the archive listing — a coarse, heap-layout-dependent disclosure of adjacent heap contents. No crash of the ordinary build occurred in the tested runs; one under a hardened allocator is plausible and was not tested. No write primitive, controlled disclosure, or code execution is claimed. The listing path reaches the read before any extraction decision, so `7zz t` and `7zz x` follow it as well.

The affected code exists in release 26.04 alone; earlier releases were inspected in source only, not executed. The 26.05 fix skips short payloads silently rather than rejecting the image; no remaining over-reading path in this branch is known, and this case does not assert a post-fix bypass or prove every later version safe.

## Credit

Fixed by Igor Pavlov in 7-Zip 26.05 (release commit [`b88c6bc0`](https://github.com/ip7z/7zip/commit/b88c6bc09339de32f7d18bbab900686b244f42ba)); the regression was introduced by the 26.04 NTFS attribute-handling rewrite (release commit [`9128b80e`](https://github.com/ip7z/7zip/commit/9128b80e3a471108678e2b3ec3c985861c8d7b0f)). No earlier public reporter was found in the checked sources as of 2026-10-28. PatchHawk flagged the changed `NtfsHandler.cpp` path in the release comparison, but its automated PoC attempt did not complete; the payload, CLI reproduction, and version sweep in this case were established by manual Docker tests.

## Author

Automatically generated by PatchHawk.
