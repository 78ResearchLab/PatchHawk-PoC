# SQUID-2026:7 — stack buffer overflow in HTTP peer authentication

| | |
|---|---|
| **Tested vulnerable** | Squid 7.6 release archive |
| **Fixed in** | Squid 7.7 release archive |
| **Advisory** | [SQUID-2026:7 / GHSA-j9pf-q9f6-v44c](https://github.com/squid-cache/squid/security/advisories/GHSA-j9pf-q9f6-v44c) (moderate, CVSS 5.4; no CVE assigned in the advisory) |
| **Fix** | [`8b3c2f2ee`](https://github.com/squid-cache/squid/commit/8b3c2f2eea22886288edb47d4c30177bf8673650) |
| **Class** | CWE-121 / CWE-787 stack out-of-bounds write |
| **Entry point** | Authenticated client HTTP request through a Squid proxy configured to forward Basic credentials to a `cache_peer` |

## At a glance

Squid 7.6 copies an authenticated client's username and the configured peer
password into a fixed-size stack buffer after Base64 encoding. In the
`cache_peer ... login=*:...` path, the username length was not checked before
encoding. A long username accepted by the authentication helper overflows the
buffer. The 7.7 fix rejects the combined input before the write.

In our Docker lab, one request with a synthetic 300-byte username caused
AddressSanitizer to report a **stack-buffer-overflow, WRITE of size 1** in
`httpFixupAuthentication()` and the instrumented 7.6 process exited. The same
request on 7.7 received `HTTP/1.1 500 Internal Server Error` with a logged
`peer login credentials too long` exception; the proxy process remained alive.

This is a configuration-dependent issue. The lab deliberately uses a parent
`cache_peer` with `login=*:s3cr3t` and Squid's shipped `basic_fake_auth` helper,
which accepts the long username. A deployment that does not pass client Basic
credentials to a peer, or whose auth helper rejects long usernames, does not
expose this particular route. The [vendor advisory](https://github.com/squid-cache/squid/security/advisories/GHSA-j9pf-q9f6-v44c)
describes the broader affected configurations.

## Root cause and fix

The released 7.6 `src/http.cc` allocates `loginbuf` using
`base64_encode_len(MAX_LOGIN_SZ)` (175 bytes here), then encodes the username
and configured peer-login suffix without checking their combined length:

```cpp
char loginbuf[base64_encode_len(MAX_LOGIN_SZ)];
// ... login=* branch ...
blen = base64_encode_update(&ctx, loginbuf, strlen(username),
                            reinterpret_cast<const uint8_t*>(username));
blen += base64_encode_update(&ctx, loginbuf+blen,
                            strlen(request->peer_login + 1),
                            reinterpret_cast<const uint8_t*>(request->peer_login + 1));
```

For this lab's `*:s3cr3t`, the suffix contributes seven bytes. The 300-byte
username makes 307 encoder input bytes; Base64 output exceeds the 175-byte
destination. The relevant 7.7 change is a guard before either encode call:

```diff
+const auto usernameLen = strlen(username);
+const auto suffixLen = strlen(request->peer_login + 1);
+if (usernameLen + suffixLen > MAX_LOGIN_SZ)
+    throw TextException("peer login credentials too long", Here());
-blen = base64_encode_update(&ctx, loginbuf, strlen(username), ...);
+blen = base64_encode_update(&ctx, loginbuf, usernameLen, ...);
```

The snippet is shortened for readability; inspect the [upstream commit](https://github.com/squid-cache/squid/commit/8b3c2f2eea22886288edb47d4c30177bf8673650)
for the full patch.

## Reproduce

Docker is the only runtime prerequisite. The script creates a private internal
Docker network and publishes no proxy port to the host.

```bash
cd GHSA-j9pf-q9f6-v44c
docker build --build-arg JOBS=4 -t squid-auth-poc:7.6-7.7 build/
./run.sh
```

The image builds both official release archives with the same AddressSanitizer
flags and verifies the downloads before extraction:

| Source archive | SHA-256 |
|---|---|
| [Squid 7.6](https://github.com/squid-cache/squid/releases/download/SQUID_7_6/squid-7.6.tar.xz) | `852178fdc37c5b0786a934fc990c7d2fffc82acf19b2284be209b96431d25992` |
| [Squid 7.7](https://github.com/squid-cache/squid/releases/download/SQUID_7_7/squid-7.7.tar.xz) | `e3bd613b91b1c498ec2992276063342a85cd6edddd5521294e04f44bc055da9b` |

Use the **7.6 release archive**, not the `SQUID_7_6` Git tag: their contents
are not identical. The tested 7.6 archive lacks the guard above.

[`build/client.py`](build/client.py) constructs the Basic-auth requests;
[`build/squid.conf.in`](build/squid.conf.in) contains both necessary config
gates; [`build/peer.py`](build/peer.py) is a local HTTP parent. `run.sh` starts
the private peer, first confirms a 100-byte username succeeds on each version,
then sends the 300-byte trigger, captures Squid's logs, and checks the
vulnerable/fixed difference. It writes fresh summaries to `output/` and fails
if the expected differential is absent. The checked-in
[7.6](output/vulnerable-7.6.txt) and [7.7](output/fixed-7.7.txt) summaries
were produced by this public script on 2026-09-29.

## Results

The preserved files in [`evidence/`](evidence/) are **unmodified logs from the
original 2026-09-01 lab run** in the PatchHawk analysis report, using the same
release archives, ASan flags, peer-login configuration, and 300-byte username.
They are separate from any fresh output produced by `run.sh`.

The [7.6 AddressSanitizer report](evidence/squid-7.6-asan.txt) includes:

```text
ERROR: AddressSanitizer: stack-buffer-overflow
WRITE of size 1
    #0 ... in encode_raw /src/squid-7.6/lib/base64.c:202
    #1 ... in base64_encode_update /src/squid-7.6/lib/base64.c:288
    #2 ... in httpFixupAuthentication /src/squid-7.6/src/http.cc:1848
    [912, 1087) 'loginbuf' (line 1832) <== Memory access at offset 1151 overflows this variable
```

The original run recorded the 7.6 container as `exited exit=1`. The
[7.7 cache log](evidence/squid-7.7-cache.log) records
`peer login credentials too long` at `http.cc(1851)`; the original run recorded
the Squid process still running and no ASan report.

## Scope and credit

The PoC proves a stack out-of-bounds write and process termination in an
**ASan-instrumented** 7.6 build. It does not demonstrate an unsanitized crash,
code execution, or behavior for every authentication helper and peer
configuration. The 7.7 rejection is a per-request error; the daemon survives.

The [Squid advisory](https://github.com/squid-cache/squid/security/advisories/GHSA-j9pf-q9f6-v44c)
credits breakingbad6, Yingpei Zeng, and Yanzhao Shen with discovery and
Francesco Chemolli with the fix. PatchHawk's 7.6-to-7.7 analysis identified
this changed route; this package adapts its original S1 lab reproducer for
independent public use.
