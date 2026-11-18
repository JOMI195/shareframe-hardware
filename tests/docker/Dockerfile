# Host test image: the scripts run under busybox built from the device's own config, so ash and
# applet behaviour match the board. Build context: br2-external/configs.
FROM debian:trixie-slim AS busybox
ARG BUSYBOX=1.37.0
ARG BUSYBOX_SHA256=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential bzip2 ca-certificates curl linux-libc-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl -fsSLo bb.tar.bz2 "https://busybox.net/downloads/busybox-${BUSYBOX}.tar.bz2" \
    && echo "${BUSYBOX_SHA256}  bb.tar.bz2" | sha256sum -c - \
    && tar xjf bb.tar.bz2 --strip-components=1
COPY busybox.conf .config
# tc and the SHA-NI paths don't build against current host headers; no script uses them.
RUN sed -i -e 's/^CONFIG_STATIC=y/# CONFIG_STATIC is not set/' \
           -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
           -e 's/^CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/' \
           -e 's/^CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/' .config \
    && yes '' | make oldconfig >/dev/null \
    && make -j"$(nproc)" busybox >/dev/null \
    && mkdir -p /opt/busybox/bin && cp busybox /opt/busybox/bin/ \
    && for a in $(./busybox --list); do ln -sf busybox "/opt/busybox/bin/$a"; done

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        bats bats-assert bats-file bats-support \
        ca-certificates gcc jq libc6-dev openssl procps python3 s6 shellcheck \
    && rm -rf /var/lib/apt/lists/*
COPY --from=busybox /opt/busybox /opt/busybox
# Like the board: #!/bin/sh is busybox ash.
RUN ln -sf /opt/busybox/bin/busybox /bin/sh
ENV BATS_LIB_PATH=/usr/lib/bats HOME=/tmp
WORKDIR /src
