# Builds OpenCV 4.13.0 (vulnerable) and 4.14.0 (fixed) from the release tarballs.
#
# The only cmake option passed is CMAKE_INSTALL_PREFIX. There is no BUILD_LIST,
# no WITH_* toggle and no CMAKE_BUILD_TYPE override, so every default OpenCV
# picks for itself is left alone -- including BUILD_opencv_apps, which is ON by
# default and produces the opencv_model_diagnostics binary used below.
#
# A second stage adds the same two versions built with AddressSanitizer. That
# build exists only to name the defect precisely; every result in the write-up
# is reproduced on the default build first.
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build pkg-config ca-certificates curl \
      python3 python3-dev python3-numpy \
      libjpeg-dev libpng-dev libtiff-dev libwebp-dev zlib1g-dev \
      libprotobuf-dev protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -sSL -o 4.13.0.tar.gz https://github.com/opencv/opencv/archive/refs/tags/4.13.0.tar.gz \
 && curl -sSL -o 4.14.0.tar.gz https://github.com/opencv/opencv/archive/refs/tags/4.14.0.tar.gz \
 && echo "1d40ca017ea51c533cf9fd5cbde5b5fe7ae248291ddf2af99d4c17cf8e13017d  4.13.0.tar.gz" | sha256sum -c - \
 && echo "ee8fb9b30eb60850431b4656447080e3737b56e45719c92b67f245950609f86e  4.14.0.tar.gz" | sha256sum -c - \
 && tar xzf 4.13.0.tar.gz && tar xzf 4.14.0.tar.gz && rm -f *.tar.gz

# default build
RUN for V in 4.13.0 4.14.0; do \
      cmake -S /src/opencv-$V -B /build/$V -G Ninja -DCMAKE_INSTALL_PREFIX=/opt/ocv-$V \
      && cmake --build /build/$V -j"$(nproc)" && cmake --install /build/$V \
      && cp /build/$V/bin/opencv_model_diagnostics /opt/ocv-$V/bin/ 2>/dev/null || true ; \
      rm -rf /build/$V ; \
    done

# Sanitizer build, used only to name the defect -- never to claim the bug needs one.
# WITH_IPP=OFF here because with IPP on, Mat::copyTo dispatches into a hand-written
# IPP routine and AddressSanitizer can only report "SEGV in icv_l9_ownsCopy_8u_repE9"
# with no source line. With IPP off the same read is reported against OpenCV's own
# code, which is what makes the transcript worth reading.
ENV SAN="-fsanitize=address,undefined -fno-omit-frame-pointer -g"
RUN for V in 4.13.0 4.14.0; do \
      cmake -S /src/opencv-$V -B /bsan/$V -G Ninja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_C_FLAGS="$SAN" -DCMAKE_CXX_FLAGS="$SAN" \
        -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined" \
        -DCMAKE_SHARED_LINKER_FLAGS="-fsanitize=address,undefined" \
        -DBUILD_LIST=core,imgproc,imgcodecs,dnn,python3 \
        -DWITH_IPP=OFF \
        -DCMAKE_INSTALL_PREFIX=/opt/san-$V \
      && cmake --build /bsan/$V -j"$(nproc)" && cmake --install /bsan/$V ; \
      rm -rf /bsan/$V ; \
    done
WORKDIR /poc
