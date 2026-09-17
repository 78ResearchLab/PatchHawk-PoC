# 78RL-2026-0005

## OpenCV: an ONNX tensor whose shape claims more data than the file carries

| | |
|---|---|
| **Affected** | OpenCV `<= 4.13.0`, and `5.0.0` |
| **Fixed in** | 4.14.0. Also fixed on the `5.x` branch, but **not in any released 5.x version** — see *Which versions are affected* |
| **Advisory** | None. `78RL-2026-0005` is a project-assigned identifier provided so the fix can be cited; the change is described upstream only as "validate onnx tensor payload size in getMatFromTensor" |
| **Severity** | Not assigned by upstream |
| **Class** | CWE-125 heap out-of-bounds **read**. The read length is taken from the file. No write and no code-execution primitive is shown |
| **Where** | `modules/dnn/src/onnx/onnx_graph_simplifier.cpp`, `getMatFromTensor()` |
| **Entry point** | `opencv_model_diagnostics -m model.onnx` — a CLI OpenCV ships by default — and `cv2.dnn.readNetFromONNX()` |

## At a glance

An ONNX model stores a tensor's shape and its payload as two independent fields. Nothing in the
format requires them to agree, so a reader has to check.

OpenCV 4.13.0 does not. It builds the destination matrix from the declared shape and then copies
into it from the payload, without comparing how many elements the shape asks for against how many
the payload holds. A tensor that declares a million floats and carries one therefore reads about
four megabytes out of a four-byte buffer.

The proof of concept is a **96-byte** ONNX file. No sanitizer build is needed to see it fail:
`opencv_model_diagnostics` segfaults on it in every environment tested, 30 runs out of 30.

The out-of-bounds read itself always happens — the sanitizer build shows it deterministically.
Whether it *faults* depends on what happens to lie past the allocation, and that varies by build
and heap layout. On two of the three builds we measured the Python binding faults too; on the
third it survives and hands back a silently-broken model instead. Both outcomes are shown below,
because the one that does not crash is the more interesting half.

The natural way to reach it is the tool OpenCV ships for exactly this purpose.
`opencv_model_diagnostics` is built by default, and its stated purpose is "run the diagnostics of
provided ONNX/TF model to obtain the information about its support" — pointing it at a model of
unknown provenance is its normal use.

## Root cause

`getMatFromTensor()` collects the declared shape, then copies the payload into a matrix of that
shape (`onnx_graph_simplifier.cpp:1704-1730`, abridged to the `FLOAT` branch — the other datatypes
have the same structure):

```cpp
    std::vector<int> sizes;
    for (int i = 0; i < tensor_proto.dims_size(); i++) {
            sizes.push_back(tensor_proto.dims(i));
    }
    if (sizes.empty())
        sizes.assign(1, 1);
    if (datatype == opencv_onnx::TensorProto_DataType_FLOAT) {

        if (!tensor_proto.float_data().empty()) {
            const ::google::protobuf::RepeatedField<float> field = tensor_proto.float_data();
            Mat(sizes, CV_32FC1, (void*)field.data()).copyTo(blob);
        }
        else {
            char* val = const_cast<char*>(tensor_proto.raw_data().c_str());
            Mat(sizes, CV_32FC1, val).copyTo(blob);
        }
    }
```

`Mat(sizes, CV_32FC1, ptr)` is the non-owning constructor: it wraps `ptr` in a matrix of the
given shape without copying and without knowing how much memory `ptr` actually points at. The
`.copyTo(blob)` that follows then reads `product(sizes)` floats out of it.

`sizes` comes from `tensor_proto.dims()`. The pointer comes from `float_data()` or `raw_data()`.
The two are never compared, so the shape alone decides how much is read.

### The fix

OpenCV 4.14.0 computes the declared element count once — saturating rather than wrapping on
overflow — and checks the payload against it before every read:

```cpp
    const size_t size_max = std::numeric_limits<size_t>::max();
    size_t total_elems = 1;
    for (size_t i = 0; i < sizes.size(); i++)
    {
        const size_t dim = static_cast<size_t>(sizes[i]);
        total_elems = (dim != 0 && total_elems > size_max / dim) ? size_max : total_elems * dim;
    }
    const auto checkPayloadSize = [&](size_t available_elems)
    {
        CV_CheckGE(available_elems, total_elems,
                   "DNN/ONNX: tensor payload is smaller than its declared shape");
    };
```

with a call on each path — the typed field and the raw bytes:

```cpp
            checkPayloadSize(field.size());
```
```cpp
            checkPayloadSize(tensor_proto.raw_data().size() / sizeof(float));
```

Every datatype branch the function handles — `FLOAT`, `FLOAT16`, `DOUBLE`, `INT32`, `INT64` —
received the same treatment; unrecognised datatypes were already rejected.

## How the proof of concept works

[`poc.onnx`](poc.onnx) is 96 bytes, produced by [`make-poc.py`](make-poc.py) — SHA-256
`105ac4fbd619cca2c7d6853780d1ca74b274467b90ad5b638beb551bc927a520`.

It is a minimal, otherwise well-formed model: one `Identity` node, one input, one output, and one
initializer. The initializer is the whole trick:

| Field | Value |
|---|---|
| `dims` | `1000000` |
| `data_type` | `FLOAT` |
| `raw_data` | 4 bytes — a single float |

So the shape asks for 1,000,000 floats and the payload supplies one. `copyTo` reads 4,000,000
bytes from a 4-byte buffer.

The generator writes the protobuf wire format directly, so reproducing the file needs no `onnx`
package — only Python's standard library.

## Which versions are affected

The fix shipped in 4.14.0 on the `4.x` branch and was forward-ported to `5.x`. **It is not in any
released 5.x version**: OpenCV 5.0.0 was tagged 2026-06-05, before the fix, and no 5.0.x release
has followed.

| Ref | Contains the fix |
|---|---|
| `4.x` branch | yes |
| `4.14.0` tag | yes |
| `5.x` branch | yes (forward-ported after 5.0.0 shipped) |
| **`5.0.0` tag** | **no** — the only 5.x release |

`pip install opencv-python` installs 5.0.0 today, and it segfaults on this file. Ubuntu 24.04's
`python3-opencv` is 4.6.0, which predates the fix and also segfaults.

## How to reproduce

Everything runs in Docker; nothing is built or installed on the host.

```bash
docker build -t opencv-poc:0005 build/
./run.sh
```

The image builds 4.13.0 and 4.14.0 from the release tarballs, verifying their SHA-256s. **The only
cmake option passed is the install prefix** — no `BUILD_LIST`, no `WITH_*` toggle, no
`CMAKE_BUILD_TYPE` override. `BUILD_opencv_apps` is ON by default, which is what produces the
`opencv_model_diagnostics` binary used below. A second, separate build adds AddressSanitizer,
used only to name the defect.

## Results

### OpenCV 4.13.0, default build

[`output/vulnerable-4.13.0.txt`](output/vulnerable-4.13.0.txt).

The shipped CLI takes a segmentation fault — **30 runs out of 30**:

```
--- shipped CLI: opencv_model_diagnostics -m poc.onnx ---
bash: line 3: 9 Segmentation fault (core dumped) .../opencv_model_diagnostics -m=/poc/poc.onnx
exit status: 139
```

The Python binding, on this build, does **not** fault. It completes the out-of-bounds read and
carries on:

```
--- public Python API: cv2.dnn.readNetFromONNX ---
OpenCV 4.13.0
[ERROR:0@0.123] global onnx_importer.cpp:909 populateNet DNN/ONNX: can't find layer for output name: 'Y'. Does model imported properly?
model LOADED, layers: 0
```

That is not the read being absent — the sanitizer transcript below shows the same call reading
4,000,000 bytes out of a 4-byte buffer on this exact build. It is the read landing in memory that
happens to be mapped, so nothing faults and `readNetFromONNX` returns a `Net` built partly from
whatever was there.

Whether it faults is heap-layout dependent, and small changes flip it: calling
`readNetFromONNX` bare, with no surrounding `try`/`except`, segfaults 15 runs out of 15 on the
same build. Both packaged builds below fault with the harness used here. We report this rather
than pick the formulation that crashes, because *not* crashing is the worse outcome for a
caller.

### OpenCV 4.14.0, default build

[`output/fixed-4.14.0.txt`](output/fixed-4.14.0.txt). The new check fires and names both numbers:

```
DNN/ONNX: tensor payload is smaller than its declared shape
(expected: 'available_elems >= total_elems'), where
    'available_elems' is 1
must be greater than or equal to
    'total_elems' is 1000000
```

Through the Python API the rejection is an ordinary catchable `cv2.error`, so a caller can handle
the bad model:

```
rejected with cv2.error:
  OpenCV(4.14.0) .../onnx_graph_simplifier.cpp:1753: error: (-2:Unspecified error) in function
  'cv::dnn::dnn4_v20260709::getMatFromTensor(...)::<lambda(size_t)>'
  > DNN/ONNX: tensor payload is smaller than its declared shape (expected: 'available_elems >= total_elems'), where
  >     'available_elems' is 1
  > must be greater than or equal to
  >     'total_elems' is 1000000
exit status: 0
```

The Python process exits 0 — the bad model is rejected, not fatal.

One honest detail: the **CLI** still exits non-zero on 4.14.0, because
`opencv_model_diagnostics` does not wrap `readNet` in a `try`/`catch` and the exception reaches
`terminate`. That is the tool's own error handling, not the library's — the library's behaviour
changed from an uncontrolled segmentation fault to a thrown `cv::Exception` carrying a diagnostic.

### OpenCV 4.13.0, AddressSanitizer build

[`output/sanitizer-4.13.0.txt`](output/sanitizer-4.13.0.txt) — this is what names the defect as a
read and locates it:

```
==1==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x503000068e80
READ of size 4000000 at 0x503000068e80 thread T0
    #2 cv::Mat::copyTo(cv::_OutputArray const&) const  modules/core/src/copy.cpp:491
    #3 cv::dnn::getMatFromTensor(opencv_onnx::TensorProto const&)
         modules/dnn/src/onnx/onnx_graph_simplifier.cpp:1727
    #4 cv::dnn::ONNXImporter::getGraphTensors(...)  modules/dnn/src/onnx/onnx_importer.cpp:422
    #5 cv::dnn::ONNXImporter::populateNet()  modules/dnn/src/onnx/onnx_importer.cpp:820
```

`READ of size 4000000` is exactly the 1,000,000 declared floats, and line 1727 is the
`Mat(sizes, CV_32FC1, val).copyTo(blob)` quoted above.

Two details about this transcript are worth stating rather than hiding:

- The sanitizer build passes `WITH_IPP=OFF`. With IPP enabled — which is the default —
  `Mat::copyTo` dispatches into a hand-written IPP routine, and AddressSanitizer can only report
  `SEGV in icv_l9_ownsCopy_8u_repE9` with no source line. The defect and the crash are identical
  either way; turning IPP off is what lets the report name OpenCV's own code.
- With a much smaller declared count (a few thousand floats) the read stays inside protobuf's own
  allocation and **no sanitizer report is produced at all**. The size used here is what carries
  the read off the end of mapped memory. That is why the shipped `poc.onnx` declares a million
  elements rather than a handful.

### Distribution packages

Transcripts in [`output/distro-ubuntu-4.6.0.txt`](output/distro-ubuntu-4.6.0.txt) and
[`output/pip-5.0.0.txt`](output/pip-5.0.0.txt):

| Source | Version | Result |
|---|---|---|
| `apt install python3-opencv` on Ubuntu 24.04 | 4.6.0 | segmentation fault — 3 runs out of 3 |
| `pip install opencv-python-headless` | 5.0.0 | segmentation fault — 3 runs out of 3 |

## Impact and limitations

This is an out-of-bounds **read** whose length is chosen by the file. There is no write on this
path, and no code-execution primitive is demonstrated.

What the read produces is not shown to escape. The bytes are copied into a `Mat` that becomes a
layer blob, so an attacker-supplied model that survives the copy could in principle carry heap
contents into an inference result — **this proof of concept does not demonstrate that**. It does
show the precondition: on the build where the Python binding does not fault,
`readNetFromONNX` returns normally after the over-read, so the out-of-bounds bytes are sitting in
a live `Net` rather than in a process that has already died.

The reachable surface is model loading. Treating a third-party ONNX file as untrusted input is
the assumption that makes this matter, and it is the assumption `opencv_model_diagnostics` is
built on: the tool exists to tell you what is in a model you have been given.

## Credit

Found by PatchHawk while diffing OpenCV 4.13.0 against 4.14.0. The defect was fixed upstream by
`uwezkhan` in [PR #29314](https://github.com/opencv/opencv/pull/29314), commit `57081ac9`, one of
a series of parser-hardening changes that author landed across OpenCV's model importers in this
release.

## Author

Automatically generated by PatchHawk.
