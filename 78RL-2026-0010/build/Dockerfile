# Builds the 7-Zip command line tool (7zz) from the 26.04 and 26.05 source
# releases, twice per release: with AddressSanitizer (clang, flags through
# MY_ARCH, which the makefile passes to the compiler and the linker) and as
# an ordinary gcc build. The same archive can then be listed by each
# version and build in turn.
#
# 7-Zip publishes no source checksums, so the SHA-256 values below pin the
# downloaded archives. The 26.04 archive is byte-identical on 7-zip.org and
# the GitHub release; 26.05's source archive is only published on GitHub.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        clang libclang-rt-18-dev llvm-18 g++ make curl ca-certificates xz-utils \
        python3 \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/llvm-symbolizer-18 /usr/bin/llvm-symbolizer

WORKDIR /build
RUN set -eux; \
    curl -fsSL -o 7z2604-src.tar.xz https://7-zip.org/a/7z2604-src.tar.xz; \
    curl -fsSL -o 7z2605-src.tar.xz \
      https://github.com/ip7z/7zip/releases/download/26.05/7z2605-src.tar.xz; \
    echo "9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6  7z2604-src.tar.xz" | sha256sum -c -; \
    echo "0b6080b8c3e7a579161d2d495224c0e51c467576cb4c7048b0ab485ef44cc22e  7z2605-src.tar.xz" | sha256sum -c -; \
    mkdir -p 26.04 26.04-normal 26.05 26.05-normal; \
    tar xJf 7z2604-src.tar.xz -C 26.04; \
    tar xJf 7z2604-src.tar.xz -C 26.04-normal; \
    tar xJf 7z2605-src.tar.xz -C 26.05; \
    tar xJf 7z2605-src.tar.xz -C 26.05-normal

RUN set -eux; \
    for V in 26.04 26.05; do \
      make -C "/build/$V/CPP/7zip/Bundles/Alone2" -f makefile.gcc -j"$(nproc)" \
        CC=clang CXX=clang++ \
        MY_ARCH="-fsanitize=address -g -fno-omit-frame-pointer"; \
    done; \
    cp /build/26.04/CPP/7zip/Bundles/Alone2/_o/7zz /usr/local/bin/7zz-vulnerable-asan; \
    cp /build/26.05/CPP/7zip/Bundles/Alone2/_o/7zz /usr/local/bin/7zz-fixed-asan

RUN set -eux; \
    for V in 26.04-normal 26.05-normal; do \
      make -C "/build/$V/CPP/7zip/Bundles/Alone2" -f makefile.gcc -j"$(nproc)"; \
    done; \
    cp /build/26.04-normal/CPP/7zip/Bundles/Alone2/_o/7zz /usr/local/bin/7zz-vulnerable; \
    cp /build/26.05-normal/CPP/7zip/Bundles/Alone2/_o/7zz /usr/local/bin/7zz-fixed

COPY make-poc.py /poc/make-poc.py
WORKDIR /poc