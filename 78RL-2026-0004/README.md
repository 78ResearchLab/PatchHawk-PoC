# 78RL-2026-0004

## OpenCV: a two-channel PAM image read as greyscale writes past the image buffer

| | |
|---|---|
| **Affected** | OpenCV `<= 4.13.0`, and `5.0.0` |
| **Fixed in** | 4.14.0. Also fixed on the `5.x` branch, but **not in any released 5.x version** — see *Which versions are affected* |
| **Advisory** | None. `78RL-2026-0004` is a project-assigned identifier provided so the fix can be cited; the change is described upstream only as "fix out-of-bounds write when reading 2-channel PAM" |
| **Severity** | Not assigned by upstream |
| **Class** | CWE-787 heap out-of-bounds **write**. The length written and the bytes written are both taken from the file. No code-execution primitive is shown |
| **Where** | `modules/imgcodecs/src/grfmt_pam.cpp`, `basic_conversion()` |
| **Entry point** | `cv2.imread(path, cv2.IMREAD_GRAYSCALE)` — decoding an image file |

## At a glance

OpenCV decodes PAM, a container format that states its own channel count. Asked for a
greyscale image, OpenCV converts whatever the file holds down to one channel.

The converter that does this had two independent mistakes, and a file declaring **two**
channels lands on both. It advances the destination three bytes for every source pixel while
the destination row holds only one byte per pixel, and it computes the end of the source from
the pixel count rather than the sample count. The result is roughly 1.5 bytes written for every
byte of row, and the last row runs off the end of the image allocation.

Both the width and the height come from the header, so the overflow length and its contents are
chosen by whoever supplies the file.

The proof of concept is a 2121-byte PAM. `cv2.imread(poc.pam, cv2.IMREAD_GRAYSCALE)` is enough:
**no sanitizer build is needed.** glibc's own heap checking aborts the process on a default
build, on the Ubuntu distribution package, and on the `opencv-python` wheel from PyPI. The exact
diagnostic glibc prints depends on which piece of heap metadata the overflow lands on — we have
seen `double free or corruption (out)`, `double free or corruption (!prev)` and
`munmap_chunk(): invalid pointer` from the same file — but the abort itself is consistent: **30
runs out of 30** on the default build, and 5 out of 5 on each packaged build. The fixed build
decodes the same file cleanly 30 times out of 30.

## Root cause

`PAMDecoder::readData()` converts a row at a time. When the file's channel count differs from
the requested one and the format has no dedicated conversion function, it calls the generic
converter, passing the file's channel count as the source sample size
(`grfmt_pam.cpp:639`):

```cpp
                            basic_conversion (src, &fmt->layout, m_channels,
                                m_width, data, target_channels, img.depth(), m_use_rgb);
```

In 4.13.0 that converter reads (`grfmt_pam.cpp:178-189`, note the misspelled parameter):

```cpp
basic_conversion (void *src, const struct channel_layout *layout, int src_sampe_size,
    int src_width, void *target, int target_channels, int target_depth, bool use_rgb)
{
    switch (target_depth) {
        case CV_8U:
        {
            uchar *d = (uchar *)target, *s = (uchar *)src,
                *end = ((uchar *)src) + src_width;
            switch (target_channels) {
                case 1:
                    for( ; s < end; d += 3, s += src_sampe_size )
                        d[0] = d[1] = d[2] = s[layout->graychan];
```

Two things are wrong in the `target_channels == 1` branch:

- `d += 3` and three stores per iteration, though a one-channel destination row advances by one
  byte per pixel. The branch was written as if the destination had three channels.
- `end` is `src + src_width`, the pixel count, but `s` advances by `src_sampe_size` bytes each
  time. For a two-channel source the loop therefore runs `src_width / 2` times rather than
  `src_width`.

Combined, a row of `WIDTH` bytes receives `3 × (WIDTH / 2)` = **1.5 × WIDTH** bytes. Rows are
contiguous inside one allocation, so the early rows scribble over the rows that follow; the last
row writes past the allocation itself.

### The fix

OpenCV 4.14.0 corrects both, in the same hunk — the destination stride for the one-channel case
and the end of the source:

```diff
             uchar *d = (uchar *)target, *s = (uchar *)src,
-                *end = ((uchar *)src) + src_width;
+                *end = ((uchar *)src) + src_width * src_sample_size;
             switch (target_channels) {
                 case 1:
-                    for( ; s < end; d += 3, s += src_sampe_size )
-                        d[0] = d[1] = d[2] = s[layout->graychan];
+                    for( ; s < end; d += 1, s += src_sample_size )
+                        d[0] = s[layout->graychan];
```

The same two-line correction is applied to the `CV_16U` branch, and the misspelled
`src_sampe_size` is renamed throughout.

## How the proof of concept works

[`poc.pam`](poc.pam) is 2121 bytes, produced by [`make-poc.py`](make-poc.py) —
SHA-256 `fa40414ec6a65db1d5544d2e997204cabe24abdbe29f0db6e1ea54175c00f718`.

Its header is ordinary:

```
P7
WIDTH 512
HEIGHT 2
DEPTH 2
MAXVAL 255
TUPLTYPE GRAYSCALE_ALPHA
ENDHDR
```

`DEPTH 2` with `TUPLTYPE GRAYSCALE_ALPHA` is a valid, self-consistent PAM — greyscale plus an
alpha channel. Reading it with `IMREAD_GRAYSCALE` asks OpenCV to drop the alpha channel, which
is the ordinary thing to do with such a file. That is the whole trigger; nothing in the file is
malformed in a way a validator would catch.

Each 512-byte destination row then receives 768 bytes. The image allocation is 1024 bytes, the
second row starts at offset 512, and writing 768 bytes from there ends at 1280 — 256 bytes past
the end.

Width and height were chosen so the overflow is large enough for glibc to notice reliably: at
this size the abort reproduced 10 times out of 10. A smaller 328-byte variant triggers the same
code path but overflows by only 32 bytes and did not reliably disturb the heap, so it is not
the one shipped here.

## Which versions are affected

The fix landed on the `4.x` branch and shipped in 4.14.0. It was also forward-ported to the
`5.x` branch. **It is not in any released 5.x version**: OpenCV 5.0.0 was tagged 2026-06-05,
before the fix, and no 5.0.x release has followed it.

Checked directly against each branch and tag:

| Ref | Contains the fix | Note |
|---|---|---|
| `4.x` branch | yes | |
| `4.14.0` tag | yes | |
| `5.x` branch | yes | forward-ported after 5.0.0 shipped |
| **`5.0.0` tag** | **no** | the only 5.x release; still carries `d[0] = d[1] = d[2] = ...` |

Two consequences worth stating plainly, both measured below:

- `pip install opencv-python` installs **5.0.0** today, and it aborts on this file.
- Ubuntu 24.04's `python3-opencv` is **4.6.0**, which predates the fix and also aborts.

## How to reproduce

Everything runs in Docker; nothing is built or installed on the host.

```bash
docker build -t opencv-poc:0004 build/
./run.sh
```

The image builds 4.13.0 and 4.14.0 from the release tarballs, whose SHA-256s it verifies. **The
only cmake option passed is the install prefix** — no `BUILD_LIST`, no `WITH_*` toggle, no
`CMAKE_BUILD_TYPE` override — so every default OpenCV chooses for itself is left in place. A
second, separate build adds AddressSanitizer, used only to name the defect; it is not needed to
see the crash.

## Results

### OpenCV 4.13.0, default build

[`output/vulnerable-4.13.0.txt`](output/vulnerable-4.13.0.txt):

```
OpenCV 4.13.0
double free or corruption (!prev)
exit status: 134
```

glibc detects the corrupted heap metadata when the allocation is released, and aborts. `imread`
never returns, so neither of the two `print` calls after it runs.

### OpenCV 4.14.0, default build

[`output/fixed-4.14.0.txt`](output/fixed-4.14.0.txt):

```
OpenCV 4.14.0
imread returned: (2, 512)
returned normally
```

The same file now decodes to the greyscale image it describes.

### OpenCV 4.13.0, AddressSanitizer build

[`output/sanitizer-4.13.0.txt`](output/sanitizer-4.13.0.txt). This is what names the defect —
a **write**, not a read:

```
==1==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x5190002007c9
WRITE of size 1 at 0x5190002007c9 thread T0
    #0 basic_conversion  modules/imgcodecs/src/grfmt_pam.cpp:189
    #1 cv::PAMDecoder::readData(cv::Mat&)  modules/imgcodecs/src/grfmt_pam.cpp:639
    #2 imread_  modules/imgcodecs/src/loadsave.cpp:602
    #3 cv::imread(...)  modules/imgcodecs/src/loadsave.cpp:762
    #4 pyopencv_cv_imread  modules/python_bindings_generator/pyopencv_generated_funcs.h:9720
```

Line 189 is the `d[0] = d[1] = d[2] = ...` store quoted above, line 639 is the call site, and
frame 4 is the `cv2.imread` binding — so the path from the Python call to the overflowing store
is unbroken. Abridged here to remove instruction addresses and the interpreter frames.

### Distribution packages

Both reproduce with no build step at all — transcripts in
[`output/distro-ubuntu-4.6.0.txt`](output/distro-ubuntu-4.6.0.txt) and
[`output/pip-5.0.0.txt`](output/pip-5.0.0.txt):

| Source | Version | Result |
|---|---|---|
| `apt install python3-opencv` on Ubuntu 24.04 | 4.6.0 | `double free or corruption (out)`, aborted (134) — 5 runs out of 5 |
| `pip install opencv-python-headless` | 5.0.0 | `double free or corruption (out)`, aborted (134) — 5 runs out of 5 |

## Impact and limitations

A heap buffer receives about 1.5 times as many bytes as it has room for. The overflow length
follows `WIDTH`, and the bytes written are the file's own pixel data passed through the greyscale
channel selector, so an attacker supplying the image chooses both.

What is demonstrated here is the overflow and the abort that follows it. **No control-flow
hijack and no information disclosure is shown**: the proof of concept does not groom the heap,
does not place a chosen object after the image allocation, and does not attempt to steer the
overwritten bytes anywhere. Whether this is exploitable beyond a crash is not established by
this write-up.

The reachable surface is ordinary image decoding. Any application that hands a user-supplied
file to `imread` with `IMREAD_GRAYSCALE` is on this path, and greyscale conversion at load time
is common in vision pipelines. PAM itself is a niche format, but `imread` selects the decoder
from the file's contents, so the caller does not have to ask for PAM to get the PAM decoder.

## Credit

Found by PatchHawk while diffing OpenCV 4.13.0 against 4.14.0. The defect was fixed upstream by
`arshsmith` in [PR #29296](https://github.com/opencv/opencv/pull/29296), commit `6df9732c`,
which also reports it as reachable through `imread`.

## Author

Automatically generated by PatchHawk.
