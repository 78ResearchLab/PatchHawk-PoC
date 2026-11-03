# 78RL-2026-0011

## PDFio: importing a 16-bit PNG with an alpha channel writes past the image buffer

| | |
|---|---|
| **Affected** | PDFio 1.6.4, for the tested PNG (source inspection: same code in 1.5.0 through 1.6.3) |
| **Fixed in** | PDFio 1.6.5 sizes the row buffer for the alpha plane at every bit depth |
| **Advisory** | No matching CVE or GHSA confirmed in the checked advisory and CVE sources as of 2026-11-03; the 1.6.5 changelog says only "Fixed import of 16-bit PNG files with alpha". `78RL-2026-0011` is a project-assigned reproducer ID, not an advisory |
| **Severity** | Not assigned by upstream |
| **Class** | CWE-787 out-of-bounds write: a heap write of attacker-chosen size and contents past the image buffer; no read primitive is shown |
| **Where** | `pdfio-content.c`, `copy_png()`, the `HAVE_LIBPNG` image-import path |
| **Entry point** | `pdfioFileCreateImageObjFromFile()`, an exported library API — an application importing an untrusted PNG. Not PDF parsing |

## At a glance

The checked-in [trigger](input/poc.png) is an 83-byte PNG, 64×8 pixels, bit depth 16, colour type RGBA. PDFio 1.6.4 sizes each row's buffer as three colour planes plus `width` bytes for alpha. At depth 16 the alpha plane needs `width × 2` bytes, so every row is short by exactly `width` bytes while libpng writes `width × 4 × 2` bytes into it.

On the ASan build of 1.6.4 the import stops with a heap-buffer-overflow write of 512 bytes past a 3584-byte region, exit 134. On an ordinary unsanitized 1.6.4 build the import corrupts the heap and glibc aborts at the next free: `double free or corruption (!prev)`, exit 134. The 1.6.5 builds import the same image cleanly.

Both the overflow's size and its contents come from the PNG. The size is the image width, which PDFio caps at 16384: the [wide trigger](input/wide.png) (1024×8) produces an 8192-byte write past a 57344-byte region, and the contents are the attacker's own pixel bytes.

## Root cause

`copy_png()` decodes the PNG into one flat `calloc(height, linesize)` allocation and hands libpng row pointers into it. In 1.6.4 the row size is:

```c
  alpha    = (color_type & PNG_COLOR_MASK_ALPHA) != 0;
  linesize = (width * num_colors * depth + 7) / 8;
  if (alpha)
    linesize += width;
```

The alpha adjustment adds `width` bytes regardless of bit depth. That is correct at depth 8 and short by `width` bytes per row at depth 16, because libpng writes native 16-bit samples — `png_get_rowbytes()` is `width * (num_colors + 1) * 2`. There is no `png_set_strip_16()` in the function. For the trigger: 1.6.4 allocates 8 × 448 = 3584 bytes, the last row starts at 3136 and receives 512 bytes, so the final 64 bytes land past the allocation — and ASan reports the whole 512-byte `memcpy` once its start address leaves the region.

The import path is on by default: `configure.ac` declares `--enable-libpng` with `default=auto`, and a stock `./configure` enables it whenever `pkg-config` finds libpng16, which every mainstream distribution does. The non-libpng fallback is not affected — it rejects alpha colour types outright.

### The fix

[1.6.5 commit `dba24899`](https://github.com/michaelrsweet/pdfio/commit/dba24899d306b5a289838b4a7185af452bc64229), "Fix line buffer size for 16-bit PNG files with alpha.":

```c
  alpha = (color_type & PNG_COLOR_MASK_ALPHA) != 0;
  if (alpha)
    linesize = (width * (num_colors + 1) * depth + 7) / 8;
  else
    linesize = (width * num_colors * depth + 7) / 8;
```

The alpha plane is now counted at the image's bit depth like the colour planes. We verified the corrected expression against libpng's `png_get_rowbytes()` for every colour type × bit depth × interlace combination the PNG specification allows (153 shapes): the two are equal in all of them. No remaining undersized-path in this function is known for released PNG variants.

## How the proof of concept works

[`make-poc.py`](make-poc.py) builds all three checked-in images from scratch with Python's standard library. Every runner regenerates them inside Docker and compares byte-for-byte with the checked-in files before invoking the target. [`import.c`](import.c) is the whole harness: it creates a PDF with `pdfioFileCreate()` and imports the image with `pdfioFileCreateImageObjFromFile()`, both exported API. No pdfio-internal function is called.

- [`run-original.sh`](run-original.sh) imports the 64×8 trigger with the ASan builds of 1.6.4 and 1.6.5.
- [`run-control.sh`](run-control.sh) imports the same image at bit depth 8 — where the two row-size expressions are equal — with both ASan builds. Both must import cleanly; the defect is specific to depth 16.
- [`run-magnitude.sh`](run-magnitude.sh) imports the 1024×8 trigger with both ASan builds.
- [`run-ordinary.sh`](run-ordinary.sh) imports the trigger with ordinary, unsanitized gcc builds of both releases.
- [`run.sh`](run.sh) verifies the image hashes, builds the Docker image, and invokes all four.

## Which versions are affected

These are Docker runs of the official release archives, not a claim about every distribution backport.

| Release and build | Input | Observed result | Evidence |
|---|---|---|---|
| 1.6.4, ASan | 64×8 depth-16 RGBA | Heap-buffer-overflow write of 512 bytes past a 3584-byte region in `copy_png`, exit 134 | [Log](output/original-1.6.4-asan.txt) |
| 1.6.4, ordinary | 64×8 depth-16 RGBA | `double free or corruption (!prev)`, SIGABRT at the next free, exit 134 | [Log](output/ordinary-1.6.4.txt) |
| 1.6.4, ASan | 1024×8 depth-16 RGBA | Heap-buffer-overflow write of 8192 bytes past a 57344-byte region, exit 134 | [Log](output/magnitude-1.6.4.txt) |
| 1.6.5, ASan and ordinary | both triggers | Image object created, exit 0 | [64×8](output/original-1.6.5-asan.txt), [wide](output/magnitude-1.6.5.txt), [ordinary](output/ordinary-1.6.5.txt) |
| 1.6.4 and 1.6.5, ASan | 64×8 depth-8 RGBA control | Both import cleanly, exit 0 | [1.6.4](output/control-1.6.4-asan.txt), [1.6.5](output/control-1.6.5-asan.txt) |

Source inspection only, not executed: the same `linesize += width` expression is present in `pdfio-content.c` at tags v1.5.0 through v1.6.3, and the alpha-channel import itself first shipped in 1.5.0 (released 2025-03-06). Tags v1.3.0 and v1.4.0 contain no alpha import at all — their fallback rejects colour type 6.

## How to reproduce

From this directory, with Docker available and the host's `rg` and `sha256sum` commands available:

```bash
./run.sh
```

The [Dockerfile](build/Dockerfile) downloads both official release archives during the image build and verifies their SHA-256 hashes before extraction; a missing or changed archive stops the build. PDFio publishes no source checksums, so the values below pin the downloaded bytes. The build also refuses to finish unless the stock `./configure --disable-shared` turned on `HAVE_LIBPNG`, because the defect lives in that path. Docker needs network access during the build; the case runs use none:

| Official source archive | SHA-256 | Resolved upstream tag |
|---|---|---|
| [pdfio-1.6.4.tar.gz](https://github.com/michaelrsweet/pdfio/releases/download/v1.6.4/pdfio-1.6.4.tar.gz) | `1b5e5e945f4fc214b55d575554c1aec11d7ba91b397cef92ffe877462155af06` | [`v1.6.4`](https://github.com/michaelrsweet/pdfio/releases/tag/v1.6.4), commit `48b185c650e2e732eed260d63909f4ec68ac9353` |
| [pdfio-1.6.5.tar.gz](https://github.com/michaelrsweet/pdfio/releases/download/v1.6.5/pdfio-1.6.5.tar.gz) | `2b9e1db7c4a72cbc896098a6682a1e51fc2bfb979f00bec8bb515ee79c338084` | [`v1.6.5`](https://github.com/michaelrsweet/pdfio/releases/tag/v1.6.5), commit `5102eddff28d9b605f3e6783d50ad380f61f692e` |

Each release is built twice with stock autotools and no feature flags: an ASan build (`gcc`, `-g -O1 -fsanitize=address -fno-omit-frame-pointer`) and an ordinary `gcc -g -O1` build. Container runs use no network, a read-only root and case mount, disabled core dumps, a 20-second time limit, and bounded memory, CPU, and process counts. The runners assert the regenerated-input match, exit status, the specific sanitizer finding or its absence, and the control results; they stop at the first mismatch. See the [asserted summary](output/reproduction.txt).

## Results

### PDFio 1.6.4: importing the trigger

The [ASan log](output/original-1.6.4-asan.txt) records the regenerated-input match and exit 134. Abridged here to shorten build paths and omit the libpng-internal frames:

```
ERROR: AddressSanitizer: heap-buffer-overflow on address 0x520000000e80
WRITE of size 512 at 0x520000000e80 thread T0
    #0 ... in memcpy .../sanitizer_common_interceptors_memintrinsics.inc:115
    #4 ... in copy_png /build/vuln-asan/pdfio-content.c:2809
    #5 ... in pdfioFileCreateImageObjFromFile /build/vuln-asan/pdfio-content.c:2206

0x520000000e80 is located 0 bytes after 3584-byte region [0x520000000080,0x520000000e80)
allocated by thread T0 here:
    #0 ... in calloc .../asan_malloc_linux.cpp:77
    #1 ... in copy_png /build/vuln-asan/pdfio-content.c:2792
```

The 3584-byte region is the image buffer (8 rows × the 1.6.4 line size 448); the 512-byte write is libpng filling the last row. The [ordinary-build log](output/ordinary-1.6.4.txt) shows the same import without a sanitizer: the process reaches `pdfioFileClose()` and glibc aborts with `double free or corruption (!prev)`, exit 134 — the heap metadata after the image buffer was overwritten by pixel data.

### Attacker-chosen magnitude

The [wide-trigger log](output/magnitude-1.6.4.txt) records `WRITE of size 8192` past a 57344-byte region on 1.6.4: the per-row shortfall is the image width, so a wider image overwrites more. PDFio calls `png_set_user_limits(pp, 16384, 16384)` before decoding, which caps the overwrite at 16384 bytes per row past the allocation.

### PDFio 1.6.5 and the depth-8 control

The 1.6.5 [ASan](output/original-1.6.5-asan.txt) and [ordinary](output/ordinary-1.6.5.txt) logs record exit 0 and a created image object for both triggers. Both releases import the [depth-8 control](output/control-1.6.4-asan.txt) cleanly — at depth 8 the old and new row-size expressions are equal, which is why the defect only appears at depth 16.

## Impact and limitations

The demonstrated effect is a heap out-of-bounds write with attacker-chosen size (up to 16384 bytes per row past the buffer) and attacker-chosen contents (the PNG's own pixel bytes), reached through an exported library API by importing an untrusted image. The ordinary build's observable outcome is the abort at the next free; the overwritten heap bytes themselves are the security impact, and no code execution is claimed or tested. Gray+alpha 16-bit images (colour type 4) take the same short-by-`width` path; this case demonstrates the RGBA variant.

The entry condition is an application that imports PNGs through `pdfioFileCreateImageObjFromFile()`. PDF parsing does not reach this code, and as of 2026-11-03 the CUPS filter library that embeds PDFio (libcupsfilters, which pins `pdfio >= 1.6.4`) contains no call to this API. One real consumer exists in the adjacent OpenPrinting stack: libcups' `ipptransform` tool accepts `image/png` input files and passes them to this exact function (`tools/ipptransform.c:848`), so with a system PDFio in the affected range an `ipptransform crafted.png` job reaches the overflow. libcups prefers a system PDFio (>= 1.2) and otherwise builds an embedded submodule, currently pinned to the fixed v1.6.6. A `--disable-libpng` build is not affected; the fallback rejects alpha colour types.

## Credit

Alpha-channel PNG import was added to PDFio after [issue #90](https://github.com/michaelrsweet/pdfio/issues/90) (January 2025) and first shipped in 1.5.0; the row-size defect shipped with it. Fixed by Michael R Sweet in 1.6.5, commit [`dba24899`](https://github.com/michaelrsweet/pdfio/commit/dba24899d306b5a289838b4a7185af452bc64229). No earlier public reporter was found in the project's issues or the checked advisory sources as of 2026-11-03. PatchHawk flagged the changed `pdfio-content.c` path in the 1.6.4 → 1.6.5 release comparison; its automated reproduction attempt failed before producing a PoC, and the payload, Docker reproduction, and version sweep in this case were built manually.

## Author

Automatically generated by PatchHawk.
