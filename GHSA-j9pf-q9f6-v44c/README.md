# GHSA-j9pf-q9f6-v44c

## Squid: a long Basic-auth username overflows the peer-login stack buffer

| | |
|---|---|
| **Affected** | Squid 7.6 |
| **Fixed in** | Squid 7.7 |
| **Advisory** | [SQUID-2026:7 / GHSA-j9pf-q9f6-v44c](https://github.com/squid-cache/squid/security/advisories/GHSA-j9pf-q9f6-v44c); no CVE assigned in the advisory |
| **Severity** | Moderate (CVSS 5.4, upstream) |
| **Class** | CWE-121 / CWE-787 stack out-of-bounds **write** |
| **Where** | `src/http.cc`, `httpFixupAuthentication()` |
| **Entry point** | Authenticated client HTTP request through a Squid proxy configured to forward Basic credentials to a `cache_peer` |

## At a glance

In the `cache_peer ... login=*:...` path, Squid 7.6 Base64-encodes an
authenticated client's username and the configured peer-login suffix into a
fixed-size stack buffer without checking their combined length. A long username
accepted by the authentication helper overflows that buffer. Squid 7.7 rejects
the combined input before encoding it.

In our Docker lab, one request with a synthetic 300-byte username caused
AddressSanitizer to report a **stack-buffer-overflow, WRITE of size 1** in
`httpFixupAuthentication()` and the instrumented 7.6 process exited. The same
request on 7.7 received `HTTP/1.1 500 Internal Server Error` with a logged
`peer login credentials too long` exception; the proxy process remained alive.

The PoC demonstrates a process exit in an ASan-instrumented build. It does not
establish a crash in an ordinary, unsanitized build or code execution.

## Root cause

The released 7.6 `src/http.cc` allocates `loginbuf` using
`base64_encode_len(MAX_LOGIN_SZ)` (175 bytes here):

```cpp
char loginbuf[base64_encode_len(MAX_LOGIN_SZ)];
```

Later in the `login=*` branch, these lines encode the username and peer-login
suffix without checking their combined length:

```cpp
blen = base64_encode_update(&ctx, loginbuf, strlen(username), reinterpret_cast<const uint8_t*>(username));
blen += base64_encode_update(&ctx, loginbuf+blen, strlen(request->peer_login +1), reinterpret_cast<const uint8_t*>(request->peer_login +1));
```

For this lab's `*:s3cr3t`, the suffix contributes seven bytes. The 300-byte
username makes 307 encoder input bytes; Base64 encoding produces 412 bytes for
the 175-byte destination.

### The fix

Squid 7.7 checks the combined length before either encode call. These are the
changed lines in the released `src/http.cc` files:

```diff
-        blen = base64_encode_update(&ctx, loginbuf, strlen(username), reinterpret_cast<const uint8_t*>(username));
-        blen += base64_encode_update(&ctx, loginbuf+blen, strlen(request->peer_login +1), reinterpret_cast<const uint8_t*>(request->peer_login +1));
+        const auto usernameLen = strlen(username);
+        const auto suffixLen = strlen(request->peer_login + 1);
+        if (usernameLen + suffixLen > MAX_LOGIN_SZ)
+            throw TextException("peer login credentials too long", Here());
+        blen = base64_encode_update(&ctx, loginbuf, usernameLen, reinterpret_cast<const uint8_t*>(username));
+        blen += base64_encode_update(&ctx, loginbuf+blen, suffixLen, reinterpret_cast<const uint8_t*>(request->peer_login +1));
```

The [upstream commit](https://github.com/squid-cache/squid/commit/8b3c2f2eea22886288edb47d4c30177bf8673650)
also guards other Base64 buffers. The guard shipped in the
[Squid 7.7 release](https://github.com/squid-cache/squid/releases/tag/SQUID_7_7).

## How the proof of concept works

[`build/client.py`](build/client.py) sends a synthetic HTTP request through
Squid with a Basic-auth username of either 100 or 300 bytes. The lab
configuration in [`build/squid.conf.in`](build/squid.conf.in) has both gates
needed to reach this path: a parent `cache_peer` with `login=*:s3cr3t`, and
Squid's shipped `basic_fake_auth` helper, which accepts the long username.
[`build/peer.py`](build/peer.py) acts as the private HTTP parent.

[`run.sh`](run.sh) starts the peer and each Squid version, first checks that
the 100-byte request reaches the peer and returns HTTP 200, then sends the
300-byte trigger. It captures Squid's logs and checks for an ASan stack write
and process exit on 7.6 versus a logged length rejection and surviving process
on 7.7. The checked-in [7.6](output/vulnerable-7.6.txt) and
[7.7](output/fixed-7.7.txt) summaries were produced by this script on
2026-09-29.

## How to reproduce

Everything runs in Docker; no Squid files are installed on the host. From this
directory, build both releases and run the comparison:

```bash
docker build --build-arg JOBS=4 -t squid-auth-poc:7.6-7.7 build/
./run.sh
```

The script creates a private internal Docker network and publishes no proxy
port to the host.

The image builds both official release archives with the same AddressSanitizer
flags and verifies the downloads before extraction:

| Source archive | SHA-256 |
|---|---|
| [Squid 7.6](https://github.com/squid-cache/squid/releases/download/SQUID_7_6/squid-7.6.tar.xz) | `852178fdc37c5b0786a934fc990c7d2fffc82acf19b2284be209b96431d25992` |
| [Squid 7.7](https://github.com/squid-cache/squid/releases/download/SQUID_7_7/squid-7.7.tar.xz) | `e3bd613b91b1c498ec2992276063342a85cd6edddd5521294e04f44bc055da9b` |

Use the **7.6 release archive**, not the `SQUID_7_6` Git tag: their contents
are not identical. The tested 7.6 archive lacks the guard above.

## Results

### Squid 7.6

[`output/vulnerable-7.6.txt`](output/vulnerable-7.6.txt) records the normal
request returning HTTP 200, followed by the long request and process exit:

```text
[client] username bytes: 100
[client] response: HTTP/1.1 200 OK
[client] username bytes: 300
[client] response: <no response>
[runner] container: exited exit=1
ERROR: AddressSanitizer: stack-buffer-overflow
WRITE of size 1
    #0 ... in encode_raw /src/squid-7.6/lib/base64.c:202
    #1 ... in base64_encode_update /src/squid-7.6/lib/base64.c:288
    #2 ... in httpFixupAuthentication /src/squid-7.6/src/http.cc:1848
    [912, 1087) 'loginbuf' (line 1832) <== Memory access at offset 1151 overflows this variable
```

The write occurs in the Base64 encoder called from the peer-authentication
path. The [full ASan report](evidence/squid-7.6-asan.txt) is an unmodified log
from the original 2026-09-01 lab run.

### Squid 7.7

[`output/fixed-7.7.txt`](output/fixed-7.7.txt) records the same normal request
returning HTTP 200. The long request gets an HTTP 500 error, while Squid stays
running:

```text
[client] username bytes: 100
[client] response: HTTP/1.1 200 OK
[client] username bytes: 300
[client] response: HTTP/1.1 500 Internal Server Error
[runner] container: running exit=0
AsyncJob::start threw exception: peer login credentials too long
```

The [original 7.7 cache log](evidence/squid-7.7-cache.log), also preserved
byte-for-byte from the 2026-09-01 lab run, identifies the guard at
`http.cc(1851)`. The public runner also checks that this version produces no
ASan report file.

## Impact and limitations

This route requires Squid to forward client-supplied Basic credentials to a
parent `cache_peer` and an authentication helper that accepts the long
username. A deployment without that peer configuration, or whose helper
rejects long usernames, does not expose this PoC's path. The
[vendor advisory](https://github.com/squid-cache/squid/security/advisories/GHSA-j9pf-q9f6-v44c)
describes the broader affected configurations.

The PoC proves a stack out-of-bounds write and process termination in an
**ASan-instrumented** 7.6 build. It does not demonstrate an unsanitized crash,
code execution, or behavior for every authentication helper and peer
configuration. The 7.7 rejection is a per-request error; the daemon survives.

## Credit

The [Squid advisory](https://github.com/squid-cache/squid/security/advisories/GHSA-j9pf-q9f6-v44c)
credits breakingbad6, Yingpei Zeng, and Yanzhao Shen with discovery and
Francesco Chemolli with the fix. PatchHawk's 7.6-to-7.7 analysis identified
this changed route; this package adapts its original S1 lab reproducer for
independent public use.

## Author

Automatically generated by PatchHawk.
