# Builds PDFio 1.6.4 (vulnerable) and 1.6.5 (fixed) from their official
# release archives, twice per release: an AddressSanitizer build (gcc,
# -fsanitize=address) and an ordinary unsanitized gcc build, then links the
# public-API driver against each. The build fails unless HAVE_LIBPNG is
# enabled by the stock ./configure, because the defect is in the libpng
# image-import path that a default distribution build compiles in.
#
# Michael R Sweet publishes the release archives on GitHub Releases; the
# SHA-256 values below pin the downloaded bytes (no upstream checksums exist).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc libc6-dev make curl ca-certificates xz-utils \
        pkg-config libpng-dev zlib1g-dev python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN set -eux; \
    curl -fsSL -o pdfio-1.6.4.tar.gz \
      https://github.com/michaelrsweet/pdfio/releases/download/v1.6.4/pdfio-1.6.4.tar.gz; \
    curl -fsSL -o pdfio-1.6.5.tar.gz \
      https://github.com/michaelrsweet/pdfio/releases/download/v1.6.5/pdfio-1.6.5.tar.gz; \
    echo "1b5e5e945f4fc214b55d575554c1aec11d7ba91b397cef92ffe877462155af06  pdfio-1.6.4.tar.gz" | sha256sum -c -; \
    echo "2b9e1db7c4a72cbc896098a6682a1e51fc2bfb979f00bec8bb515ee79c338084  pdfio-1.6.5.tar.gz" | sha256sum -c -; \
    mkdir -p vuln-asan vuln-plain fix-asan fix-plain; \
    tar xzf pdfio-1.6.4.tar.gz -C vuln-asan  --strip-components=1; \
    tar xzf pdfio-1.6.4.tar.gz -C vuln-plain --strip-components=1; \
    tar xzf pdfio-1.6.5.tar.gz -C fix-asan   --strip-components=1; \
    tar xzf pdfio-1.6.5.tar.gz -C fix-plain  --strip-components=1

# Stock autotools build, the same for every variant. No --enable/--disable
# feature flags: --enable-libpng defaults to auto and turns on whenever
# pkg-config finds libpng16, which is why a distribution build has it.
RUN set -eux; \
    cd /build/vuln-asan;  CC=gcc CFLAGS="-g -O1 -fsanitize=address -fno-omit-frame-pointer" LDFLAGS="-g -O1 -fsanitize=address -fno-omit-frame-pointer" ./configure --disable-shared; \
    cd /build/fix-asan;   CC=gcc CFLAGS="-g -O1 -fsanitize=address -fno-omit-frame-pointer" LDFLAGS="-g -O1 -fsanitize=address -fno-omit-frame-pointer" ./configure --disable-shared; \
    cd /build/vuln-plain; CC=gcc CFLAGS="-g -O1" LDFLAGS="-g -O1" ./configure --disable-shared; \
    cd /build/fix-plain;  CC=gcc CFLAGS="-g -O1" LDFLAGS="-g -O1" ./configure --disable-shared; \
    for v in vuln-asan fix-asan vuln-plain fix-plain; do \
      grep -q 'HAVE_LIBPNG=1' /build/$v/Makefile \
        || { echo "BUILD REFUSED: HAVE_LIBPNG not enabled in $v" >&2; exit 1; }; \
      make -C /build/$v -j"$(nproc)" libpdfio.a; \
    done

COPY make-poc.py /poc/make-poc.py
COPY import.c    /poc/import.c

RUN set -eux; \
    gcc -g -O1 -fsanitize=address -fno-omit-frame-pointer -I /build/vuln-asan \
        -o /usr/local/bin/import-164-vuln-asan /poc/import.c /build/vuln-asan/libpdfio.a \
        $(pkg-config --libs libpng16) -lz -lm; \
    gcc -g -O1 -fsanitize=address -fno-omit-frame-pointer -I /build/fix-asan \
        -o /usr/local/bin/import-165-fix-asan /poc/import.c /build/fix-asan/libpdfio.a \
        $(pkg-config --libs libpng16) -lz -lm; \
    gcc -g -O1 -I /build/vuln-plain -o /usr/local/bin/import-164-plain \
        /poc/import.c /build/vuln-plain/libpdfio.a $(pkg-config --libs libpng16) -lz -lm; \
    gcc -g -O1 -I /build/fix-plain -o /usr/local/bin/import-165-plain \
        /poc/import.c /build/fix-plain/libpdfio.a $(pkg-config --libs libpng16) -lz -lm

WORKDIR /poc
