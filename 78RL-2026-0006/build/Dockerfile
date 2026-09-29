# Build the vulnerable and fixed OpenImageIO releases with identical ASan
# instrumentation. Release archives are pinned by SHA-256 for reproducibility.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG JOBS=8

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates cmake curl git ninja-build pkg-config \
      libboost-dev libboost-filesystem-dev libboost-thread-dev \
      libexpat1-dev libfmt-dev libgif-dev libimath-dev libjpeg-dev \
      libopenexr-dev libpng-dev libpugixml-dev robin-map-dev \
      libtiff-dev libyaml-cpp-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN curl -fL --retry 3 -o OpenColorIO-2.5.1.tar.gz \
      https://github.com/AcademySoftwareFoundation/OpenColorIO/archive/refs/tags/v2.5.1.tar.gz \
 && echo "08cb6213ea4edee550ab050509d38204004bee6742c658166b1cf825d0a9381b  OpenColorIO-2.5.1.tar.gz" | sha256sum -c - \
 && tar xzf OpenColorIO-2.5.1.tar.gz \
 && rm OpenColorIO-2.5.1.tar.gz \
 && cmake -S /src/OpenColorIO-2.5.1 -B /build/ocio -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_INSTALL_PREFIX=/opt/ocio \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DBUILD_SHARED_LIBS=ON \
      -DOCIO_BUILD_APPS=OFF \
      -DOCIO_BUILD_GPU_TESTS=OFF \
      -DOCIO_BUILD_PYTHON=OFF \
      -DOCIO_BUILD_TESTS=OFF \
      -DOCIO_USE_OIIO_FOR_APPS=OFF \
      -DOCIO_INSTALL_DOCS=OFF \
      -DOCIO_INSTALL_EXT_PACKAGES=MISSING \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
 && cmake --build /build/ocio --parallel "${JOBS}" \
 && cmake --install /build/ocio \
 && rm -rf /build/ocio /src/OpenColorIO-2.5.1

ENV CMAKE_PREFIX_PATH=/opt/ocio
ENV LD_LIBRARY_PATH=/opt/ocio/lib

RUN curl -fL --retry 3 -o OpenImageIO-3.1.15.0.tar.gz \
      https://github.com/AcademySoftwareFoundation/OpenImageIO/archive/refs/tags/v3.1.15.0.tar.gz \
 && curl -fL --retry 3 -o OpenImageIO-3.1.16.0.tar.gz \
      https://github.com/AcademySoftwareFoundation/OpenImageIO/archive/refs/tags/v3.1.16.0.tar.gz \
 && echo "7837a2058638dd9caa352d6936677dba7883105c6db6caf6fb58ba40fa2c12c8  OpenImageIO-3.1.15.0.tar.gz" | sha256sum -c - \
 && echo "5af7221be05bbe69d7ec4eb74b5656c6d15b8d1a332410d6af937b1df48647c0  OpenImageIO-3.1.16.0.tar.gz" | sha256sum -c - \
 && tar xzf OpenImageIO-3.1.15.0.tar.gz \
 && tar xzf OpenImageIO-3.1.16.0.tar.gz \
 && rm OpenImageIO-3.1.15.0.tar.gz OpenImageIO-3.1.16.0.tar.gz

ENV SANITIZER_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1"

RUN for version in 3.1.15.0 3.1.16.0; do \
      cmake -S "/src/OpenImageIO-${version}" -B "/build/oiio-${version}" -G Ninja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_C_FLAGS="${SANITIZER_FLAGS}" \
        -DCMAKE_CXX_FLAGS="${SANITIZER_FLAGS}" \
        -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O1 -g -DNDEBUG" \
        -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O1 -g -DNDEBUG" \
        -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address" \
        -DCMAKE_SHARED_LINKER_FLAGS="-fsanitize=address" \
        -DCMAKE_INSTALL_PREFIX="/opt/oiio-${version}" \
        -DOpenColorIO_ROOT=/opt/ocio \
        -DUSE_PYTHON=OFF \
        -DOIIO_BUILD_TESTS=OFF \
        -DBUILD_DOCS=OFF \
        -DUSE_OPENCV=OFF \
        -DUSE_FFMPEG=OFF \
        -DUSE_FREETYPE=OFF \
        -DUSE_OPENVDB=OFF \
        -DUSE_QT=OFF \
        -DUSE_LIBRAW=OFF \
        -DUSE_OPENJPEG=OFF \
        -DUSE_WEBP=OFF \
        -DUSE_HEIF=OFF \
        -DUSE_PTEX=OFF \
        -DUSE_R3DSDK=OFF \
        -DUSE_NUKE=OFF \
        -DENABLE_iv=OFF \
        -DSTOP_ON_WARNING=OFF \
      && cmake --build "/build/oiio-${version}" --parallel "${JOBS}" \
      && cmake --install "/build/oiio-${version}" \
      && rm -rf "/build/oiio-${version}"; \
    done \
 && rm -rf /src/OpenImageIO-3.1.15.0 /src/OpenImageIO-3.1.16.0

COPY oiio_read.cpp /harness/oiio_read.cpp

RUN for version in 3.1.15.0 3.1.16.0; do \
      g++ -std=c++17 ${SANITIZER_FLAGS} \
        -I"/opt/oiio-${version}/include" \
        -I/usr/include/Imath -I/usr/include/OpenEXR \
        /harness/oiio_read.cpp -o "/usr/local/bin/oiio-read-${version}" \
        -L"/opt/oiio-${version}/lib" \
        -Wl,-rpath,"/opt/oiio-${version}/lib" \
        -lOpenImageIO -lOpenImageIO_Util; \
    done

WORKDIR /poc
