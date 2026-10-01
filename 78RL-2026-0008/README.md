# 78RL-2026-0008

## FFmpeg: a continued Ogg packet causes a wrapped buffer allocation and invalid write

| | |
|---|---|
| **Affected** | FFmpeg 9.0.1 with a raised allocation limit and this large Ogg input |
| **Fixed in** | FFmpeg 9.0.2 for the tested input |
| **Advisory** | No CVE or dedicated advisory confirmed in [FFmpeg's security list](https://ffmpeg.org/security.html) as of 2026-10-01. `78RL-2026-0008` is a project-assigned reproducer ID |
| **Severity** | Not assigned by upstream for this finding |
| **Class** | CWE-190 unsigned integer wraparound leading to an invalid write (CWE-787); AddressSanitizer labels the observed fault `unknown-crash` |
| **Where** | `libavformat/oggdec.c`, `buf_realloc()` and `ogg_read_page()` |
| **Entry point** | `ffprobe -max_alloc 8589934592 -f ogg -show_packets continued-4g.ogg` on a local file |

## At a glance

One unterminated Opus packet spans 66,000 Ogg data pages. With FFmpeg's public
allocation limit raised to 8 GiB, `ffprobe` 9.0.1 doubles an unsigned buffer
size past its representable range. AddressSanitizer reports an invalid
31,895-byte write while `ogg_read_page()` reads the next page. FFmpeg 9.0.2
rejects the same input with `Cannot allocate memory` before that write.

The file has a 4,310,262,091-byte logical length. The checked-in
[`91-byte prefix`](input/poc-prefix.ogg) and [generator](make-ogg-overflow.c)
rebuild it as a sparse file inside Docker. The runner checks the resulting
SHA-256 before invoking either release. With the default allocation limit,
both releases reject the input before the fault; that control is separate
from the raised-limit comparison.

## Root cause

In 9.0.1, `buf_realloc()` doubles `os->bufsize`, an `unsigned int`, and adds
the input-buffer padding before calling `av_realloc()`:

```c
uint8_t *nb = av_realloc(os->buf, 2*os->bufsize + AV_INPUT_BUFFER_PADDING_SIZE);
```

Once `os->bufsize` exceeds about half of `UINT_MAX`, that expression can
wrap to a small allocation size. The next `ogg_read_page()` uses the
continued packet's buffer position when it reads another page. The upstream
commit describes the resulting out-of-bounds write. In this Docker run, ASan
reports `WRITE of size 31895` through `avio_read()` at
`oggdec.c:409`. Its diagnostic category is `unknown-crash`, so this case does
not present the trace as an ASan `heap-buffer-overflow` classification.

### The fix

[Commit `16daade`](https://github.com/FFmpeg/FFmpeg/commit/16daadeabbced8fc2aa467531d654bd3b0ad47bc),
included in 9.0.2, checks the size before the doubling expression:

```diff
-        uint8_t *nb = av_realloc(os->buf, 2*os->bufsize + AV_INPUT_BUFFER_PADDING_SIZE);
+        uint8_t *nb;
+        if (os->bufsize > (UINT_MAX - AV_INPUT_BUFFER_PADDING_SIZE) / 2)
+            return AVERROR(ENOMEM);
+        nb = av_realloc(os->buf, 2*os->bufsize + AV_INPUT_BUFFER_PADDING_SIZE);
```

For this input, the patched CLI returns a normal allocation error without an
ASan diagnostic. This test does not establish that every possible Ogg buffer
growth path is safe.

## How the proof of concept works

[`input/poc-prefix.ogg`](input/poc-prefix.ogg) contains the complete Opus
identification and comment pages. It is a seed, not a crashing file.
[`make-ogg-overflow.c`](make-ogg-overflow.c) appends 66,000 valid-CRC Ogg
pages with 255 lacing entries of 255 bytes each. Page 2 begins the packet;
later pages mark it as continued. Each data page has a 282-byte header and
65,025 zero payload bytes. The generator seeks over the zeros, keeping the
local file sparse, and truncates it to its exact logical length. The full
file's expected SHA-256 is
`1931adaa1a215bafabb99108c623cb76d750e87d7296fe4fbe08852081ee06dd`.
The [reproduction summary](output/reproduction.txt) records the size and hash.

[`run.sh`](run.sh) starts the bounded Docker container.
[`run-in-container.sh`](run-in-container.sh) generates and verifies the file,
then runs the real `ffprobe` CLI on both releases with `-max_alloc 8589934592`.
It also runs each release without `-max_alloc` as a negative control. The
[`output/`](output/) directory keeps one log per raised-limit run, one shared
control log, and a short reproduction summary. Each run log shows the command,
exit status, and diagnostic output.
The runner fails unless the release-specific symptom and control results match.

## Which versions are affected

These are Docker runs of the same generated file; other releases, branches,
distribution builds, and network entry paths were not tested.

| Release | CLI input | Expected symptom | Observed result and basis |
|---|---|---|---|
| 9.0.1 | Generated Ogg, `-max_alloc 8589934592` | ASan invalid write | ASan write, exit 134; Docker [run log](output/vulnerable-9.0.1.txt) |
| 9.0.2 | Same file and raised limit | `ENOMEM` without sanitizer fault | `ENOMEM`, exit 1; Docker [run log](output/fixed-9.0.2.txt) |
| 9.0.1 | Same file, default allocation limit | `ENOMEM` before fault | `ENOMEM`, exit 1; Docker [controls](output/controls.txt) |
| 9.0.2 | Same file, default allocation limit | `ENOMEM` before fault | `ENOMEM`, exit 1; Docker [controls](output/controls.txt) |

## How to reproduce

From this case directory:

```bash
docker build --progress=plain -t ffmpeg-ogg-poc:0008 -f build/Dockerfile .
./run.sh
```

The [Dockerfile](build/Dockerfile) downloads and SHA-256 checks both official
FFmpeg source archives before building `ffprobe` with identical AddressSanitizer
and UndefinedBehaviorSanitizer flags. The runner confirms both executable
versions in the [reproduction summary](output/reproduction.txt).

| Official source archive | SHA-256 |
|---|---|
| [FFmpeg 9.0.1](https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz) | `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635` |
| [FFmpeg 9.0.2](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz) | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` |

The container has no network access at run time, no added capabilities or
published ports, a 14 GiB memory cap, and a 300-second limit for each CLI
invocation. It generates the sparse input in an ephemeral container directory;
the small logs remain under `output/`.

## Results

### FFmpeg 9.0.1 with the raised allocation limit

The [run log](output/vulnerable-9.0.1.txt) contains these stable
substrings (addresses omitted):

```text
ERROR: AddressSanitizer: unknown-crash
WRITE of size 31895
in ogg_read_page src/libavformat/oggdec.c:409
```

That log records exit `134`. The write
occurs in `avio_read()` after `buf_realloc()`; the stack shows the real
`ffprobe` → `avformat_open_input()` → Ogg demuxer path.

### FFmpeg 9.0.2 with the raised allocation limit

The [run log](output/fixed-9.0.2.txt) contains
`Cannot allocate memory` and records exit `1`. No sanitizer diagnostic appears. This is an expected guarded
failure, not a successful packet decode.

### Default-limit controls

Without `-max_alloc`, both runs in the [control log](output/controls.txt) return
`Cannot allocate memory`, exit `1`, and produce no sanitizer finding. These
controls show that the raised allocation limit is required for this trigger.

## Impact and limitations

The observed effect is an ASan-detected invalid write while a local CLI reads
a very large crafted Ogg file. An application would need to accept such a file
and permit allocations beyond FFmpeg's default limit for this exact input to
reach the fault. The file's logical size exceeds 4 GiB; its sparse layout
keeps disk use lower, but parsing still requires substantial memory and time.

This case does not test an ordinary unsanitized build, a remote daemon, code
execution, or control over the written bytes. The ASan `unknown-crash` label
does not prove a more specific allocation-boundary layout. Only the two named
releases and the two allocation settings above were run.

## Credit

The [original upstream commit](https://github.com/FFmpeg/FFmpeg/commit/d7d119bbe26c7e5c27a8b50fc8a25da43564c48a)
records `zhorzhetta1404-ux` as author, `age5000` as signer, and Romain Beauxis
as committer. Michael Niedermayer committed the
[9.0.2 backport](https://github.com/FFmpeg/FFmpeg/commit/16daadeabbced8fc2aa467531d654bd3b0ad47bc).
PatchHawk flagged the release change; manual Docker testing produced the paired
CLI evidence packaged here.

## Author

Automatically generated by PatchHawk.
