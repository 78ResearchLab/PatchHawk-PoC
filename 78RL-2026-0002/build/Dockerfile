# Builds the 7-Zip command line tool (7zz) from the 26.02 and 26.03 source
# releases, both with AddressSanitizer, so the same archive can be handled by
# each version in turn.
#
# 7-Zip ships a plain GNU makefile rather than a configure script, so the
# sanitizer flags are injected through the MY_ARCH variable, which the makefile
# passes to both the compiler and the linker. Assembly is left off so that
# every routine is compiled C and therefore instrumented.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        clang libclang-rt-18-dev llvm make curl ca-certificates xz-utils python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN set -eux; \
    curl -fsSL -o 7z2602-src.tar.xz https://7-zip.org/a/7z2602-src.tar.xz; \
    curl -fsSL -o 7z2603-src.tar.xz https://7-zip.org/a/7z2603-src.tar.xz; \
    echo "cf967c98bca02a4b8b16375f441825a8e141362f14be1969bbec8e1ca0bff9dd  7z2602-src.tar.xz" | sha256sum -c -; \
    echo "9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4  7z2603-src.tar.xz" | sha256sum -c -; \
    mkdir -p 26.02 26.03; \
    tar xJf 7z2602-src.tar.xz -C 26.02; \
    tar xJf 7z2603-src.tar.xz -C 26.03

RUN set -eux; \
    for V in 26.02 26.03; do \
      make -C "/build/$V/CPP/7zip/Bundles/Alone2" -f makefile.gcc -j"$(nproc)" \
        CC=clang CXX=clang++ \
        MY_ARCH="-fsanitize=address -g -fno-omit-frame-pointer"; \
    done; \
    cp /build/26.02/CPP/7zip/Bundles/Alone2/_o/7zz /usr/local/bin/7zz-vulnerable; \
    cp /build/26.03/CPP/7zip/Bundles/Alone2/_o/7zz /usr/local/bin/7zz-fixed

COPY run.sh /opt/run.sh
RUN chmod +x /opt/run.sh
WORKDIR /poc
ENTRYPOINT ["/opt/run.sh"]
