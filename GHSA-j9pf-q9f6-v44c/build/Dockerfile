# Build both shipped Squid releases with the same AddressSanitizer settings.
# Use release archives: the SQUID_7_6 git tag differs from the 7.6 asset.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG JOBS=4

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl libcppunit-dev libltdl-dev \
      libssl-dev libtool libxml2-dev pkg-config python3 xz-utils zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -M -d /nonexistent -s /usr/sbin/nologin squid

WORKDIR /src
RUN curl -fL --retry 3 -o squid-7.6.tar.xz \
      https://github.com/squid-cache/squid/releases/download/SQUID_7_6/squid-7.6.tar.xz \
 && curl -fL --retry 3 -o squid-7.7.tar.xz \
      https://github.com/squid-cache/squid/releases/download/SQUID_7_7/squid-7.7.tar.xz \
 && echo '852178fdc37c5b0786a934fc990c7d2fffc82acf19b2284be209b96431d25992  squid-7.6.tar.xz' | sha256sum -c - \
 && echo 'e3bd613b91b1c498ec2992276063342a85cd6edddd5521294e04f44bc055da9b  squid-7.7.tar.xz' | sha256sum -c - \
 && tar xf squid-7.6.tar.xz \
 && tar xf squid-7.7.tar.xz \
 && rm squid-7.6.tar.xz squid-7.7.tar.xz

ENV SANITIZER_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1"

RUN set -eu; for version in 7.6 7.7; do \
      cd "/src/squid-${version}"; \
      CFLAGS="${SANITIZER_FLAGS}" CXXFLAGS="${SANITIZER_FLAGS}" \
        LDFLAGS="-fsanitize=address" ./configure \
          --prefix="/opt/squid-${version}" \
          --with-default-user=squid \
          --disable-strict-error-checking \
          --enable-auth-basic=fake \
          --disable-auth-digest --disable-auth-negotiate --disable-auth-ntlm \
          --disable-external-acl-helpers \
          --disable-url-rewrite-helpers --disable-storeid-rewrite-helpers \
          --disable-log-daemon-helpers \
          --disable-security-cert-validators --disable-security-cert-generators \
          --disable-snmp --disable-htcp --disable-wccp --disable-wccpv2 \
          --disable-eui --disable-esi --disable-icap-client --disable-ecap \
          --disable-cache-digests --disable-delay-pools \
          > /tmp/configure.log 2>&1 || { tail -80 /tmp/configure.log; exit 1; }; \
      make -j"${JOBS}" > /tmp/build.log 2>&1 || { tail -100 /tmp/build.log; exit 1; }; \
      make install > /tmp/install.log 2>&1 || { tail -80 /tmp/install.log; exit 1; }; \
      mkdir -p "/opt/squid-${version}/var/logs" \
               "/opt/squid-${version}/var/cache" \
               "/opt/squid-${version}/var/run"; \
      chown -R squid:squid "/opt/squid-${version}/var"; \
      cd /src; rm -rf "squid-${version}"; \
    done

COPY squid.conf.in /poc/squid.conf.in
COPY peer.py client.py /poc/
WORKDIR /poc
