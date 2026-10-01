# Build both official FFmpeg releases with identical AddressSanitizer and
# UndefinedBehaviorSanitizer instrumentation. The final image contains only
# the CLI binaries and runtime libraries needed for the reproduction.
FROM ubuntu:24.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG JOBS=12

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl nasm pkg-config xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fL --retry 3 -o ffmpeg-9.0.1.tar.xz \
      https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz \
 && curl -fL --retry 3 -o ffmpeg-9.0.2.tar.xz \
      https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz \
 && echo 'cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635  ffmpeg-9.0.1.tar.xz' | sha256sum -c - \
 && echo '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e  ffmpeg-9.0.2.tar.xz' | sha256sum -c - \
 && tar xf ffmpeg-9.0.1.tar.xz \
 && tar xf ffmpeg-9.0.2.tar.xz \
 && rm ffmpeg-9.0.1.tar.xz ffmpeg-9.0.2.tar.xz

RUN set -eu; for version in 9.0.1 9.0.2; do \
      mkdir -p "/build/${version}"; \
      cd "/build/${version}"; \
      "/src/ffmpeg-${version}/configure" \
        --disable-autodetect \
        --disable-doc \
        --disable-ffplay \
        --disable-ffprobe \
        --disable-stripping \
        --enable-debug=1 \
        --extra-cflags='-fsanitize=address,undefined -fno-omit-frame-pointer -O1' \
        --extra-ldflags='-fsanitize=address,undefined' \
        > /tmp/configure.log 2>&1 || { tail -80 /tmp/configure.log; exit 1; }; \
      make -j"${JOBS}" ffmpeg > /tmp/build.log 2>&1 \
        || { tail -100 /tmp/build.log; exit 1; }; \
      cp ffmpeg "/opt/ffmpeg-${version}"; \
      cd /; rm -rf "/build/${version}" "/src/ffmpeg-${version}"; \
    done

FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      libasan8 libubsan1 coreutils \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/ffmpeg-9.0.1 /opt/ffmpeg-9.0.1
COPY --from=builder /opt/ffmpeg-9.0.2 /opt/ffmpeg-9.0.2
WORKDIR /poc
