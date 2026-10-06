FROM --platform=linux/386 debian:trixie

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates cmake curl ninja-build pkg-config \
    libhwy-dev libbrotli-dev liblcms2-dev libpng-dev \
    && rm -rf /var/lib/apt/lists/*

ARG JXL_VERSION
RUN case "$JXL_VERSION" in \
      0.11.1) expected=1492dfef8dd6c3036446ac3b340005d92ab92f7d48ee3271b5dac1d36945d3d9 ;; \
      0.11.2) expected=ab38928f7f6248e2a98cc184956021acb927b16a0dee71b4d260dc040a4320ea ;; \
      *) exit 2 ;; \
    esac && \
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 \
      "https://codeload.github.com/libjxl/libjxl/tar.gz/refs/tags/v${JXL_VERSION}" \
      --output /tmp/libjxl.tar.gz && \
    printf '%s  %s\n' "$expected" /tmp/libjxl.tar.gz | sha256sum -c -
RUN mkdir -p /src && tar -xzf /tmp/libjxl.tar.gz -C /src --strip-components=1

RUN cmake -S /src -B /build -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DJPEGXL_ENABLE_SKCMS=OFF \
    -DJPEGXL_FORCE_SYSTEM_LCMS2=ON \
    -DJPEGXL_FORCE_SYSTEM_HWY=ON \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=ON \
    -DJPEGXL_ENABLE_TOOLS=ON \
    -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_ENABLE_JPEGLI=OFF \
    -DJPEGXL_ENABLE_SJPEG=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF \
    -DBUILD_TESTING=OFF \
    && cmake --build /build --target djxl -j 4

COPY make-poc.cc /poc/make-poc.cc
RUN c++ -O1 -g -I/src/lib/include -I/build/lib/include -I/build/include \
    /poc/make-poc.cc -L/build/lib -Wl,-rpath,/build/lib \
    -ljxl -ljxl_threads -o /poc/make-poc

ENV LD_LIBRARY_PATH=/build/lib
WORKDIR /poc
