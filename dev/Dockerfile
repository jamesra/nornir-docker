# Build from monorepo root:
#   docker build -f nornir-docker/dev/Dockerfile -t nornir:dev .
# Cursor worker base (no monorepo under /opt/nornir):
#   docker build -f nornir-docker/dev/Dockerfile --build-arg INSTALL_MONOREPO_EDITABLES=0 -t nornir:dev-cursor-base .
#
# Headless Nornir stack (no Pyre). Python 3.14 + ImageMagick 7.
# Always includes CuPy for GPU debugging; pass --gpus all (or nd-build -Gpu) at run time to use the GPU.

FROM python:3.14-bookworm

ARG NORNIR_RELEASE=0.0.0-dev
ARG SOURCE_REVISION=unknown
ARG BUILD_DATE=unknown
ARG IMAGE_SOURCE=https://github.com/jamesra/nornir
ARG NORNIR_IMAGE_VARIANT=dev
ARG PACKAGE_VERSIONS_JSON_B64=
ARG IMAGE_TITLE=Nornir development image
ARG IMAGE_DESCRIPTION=Headless Nornir stack with pytest and CuPy for Python 3.14

LABEL org.opencontainers.image.title="${IMAGE_TITLE}" \
      org.opencontainers.image.description="${IMAGE_DESCRIPTION}" \
      org.opencontainers.image.version="${NORNIR_RELEASE}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="LicenseRef-Nornir-See-Repository" \
      org.nornir.variant="${NORNIR_IMAGE_VARIANT}" \
      org.nornir.package_versions.json.base64="${PACKAGE_VERSIONS_JSON_B64}"

ARG DEBIAN_FRONTEND=noninteractive
ARG MAGICKVERSION=7.1.1-27
# Default CuPy wheel = highest CUDA major offered for current CuPy (see docs.cupy.dev install matrix).
ARG CUPY_PACKAGE=cupy-cuda13x
# NVIDIA Debian 12 metapackage suffix (cuda-libraries-${NVIDIA_CUDA_APT_VERSION}); stay within CuPy-supported toolkit for that wheel.
ARG NVIDIA_CUDA_APT_VERSION=13-3

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git wget ca-certificates autoconf pkg-config build-essential \
        libpng-dev libjpeg62-turbo-dev libopenjp2-7-dev libtiff-dev libxml2-dev \
        zlib1g-dev libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

# ImageMagick from source (releases: https://github.com/ImageMagick/ImageMagick/releases/)
WORKDIR /usr/src
RUN wget -q "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${MAGICKVERSION}.tar.gz" \
    && tar xzf "${MAGICKVERSION}.tar.gz" \
    && rm "${MAGICKVERSION}.tar.gz"
WORKDIR /usr/src/ImageMagick-${MAGICKVERSION}
RUN ./configure \
        --prefix=/usr/local \
        --with-bzlib=yes --with-fontconfig=no --with-freetype=no \
        --with-gslib=no --with-gvc=no --with-jpeg=yes --with-jp2=yes \
        --with-png=yes --with-tiff=yes --with-xml=yes --with-gs-font-dir=no \
        --enable-static=no \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig /usr/local/lib/

WORKDIR /usr/src
RUN rm -rf "/usr/src/ImageMagick-${MAGICKVERSION}"

RUN apt-get purge -y build-essential \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# OpenGL for PyOpenGL (nornir-pyre gl_engine): libGL for GLX; libosmesa6 + PYOPENGL_PLATFORM=osmesa
# for headless import without an X display.
# mosquitto: optional MQTT log broker for nornir_shared.prettyoutput (localhost:1883)
# cifs-utils / nfs-common: optional in-container NAS mounts (NORNIR_NET_MOUNTS=1 + compose override)
# libcap2-bin: capsh fallback to drop CAP_SYS_ADMIN after mounts
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgl1 libosmesa6 mosquitto mosquitto-clients \
        cifs-utils nfs-common keyutils libcap2-bin \
    && rm -rf /var/lib/apt/lists/*

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    NORNIR_HEADLESS=1 \
    PYOPENGL_PLATFORM=osmesa

RUN python -m venv /opt/venv
ENV PATH="/root/scripts:/opt/venv/bin:$PATH"

RUN pip install --upgrade pip setuptools wheel

COPY nornir-docker/install-nvidia-cuda-runtime-apt.sh /tmp/install-nvidia-cuda-runtime-apt.sh
RUN chmod +x /tmp/install-nvidia-cuda-runtime-apt.sh \
    && NVIDIA_CUDA_APT_VERSION="${NVIDIA_CUDA_APT_VERSION}" CUPY_PACKAGE="${CUPY_PACKAGE}" \
       /tmp/install-nvidia-cuda-runtime-apt.sh \
    && rm -f /tmp/install-nvidia-cuda-runtime-apt.sh

COPY nornir-docker/constraints-headless.txt /tmp/constraints-headless.txt
RUN pip install --no-cache-dir -r /tmp/constraints-headless.txt \
    && rm -f /tmp/constraints-headless.txt

RUN pip install --no-cache-dir "${CUPY_PACKAGE}" 

# Cursor worker builds with INSTALL_MONOREPO_EDITABLES=0: venv + CuPy only; packages come from /workspace (cursor-dev-entry.sh).
ARG INSTALL_MONOREPO_EDITABLES=1
WORKDIR /opt/nornir
COPY nornir-shared ./nornir-shared
COPY nornir-pools ./nornir-pools
COPY nornir-imageregistration ./nornir-imageregistration
COPY dm4 ./dm4
COPY nornir-buildmanager ./nornir-buildmanager

# TEM pipeline wrappers for interactive shells (~/scripts on PATH). Copy before optional package rm.
# Install TEM* without .sh; keep _nornir_tem_common.sh for sourced helpers.
RUN mkdir -p /root/scripts \
    && for f in ./nornir-buildmanager/scripts/TEM*.sh; do \
         cp "$f" "/root/scripts/$(basename "${f%.sh}")"; \
       done \
    && cp ./nornir-buildmanager/scripts/_nornir_tem_common.sh /root/scripts/ \
    && sed -i 's/\r$//' /root/scripts/* \
    && chmod +x /root/scripts/*

COPY nornir-docker/install-monorepo-editables.sh /tmp/install-monorepo-editables.sh

# Local pyprojects reference git URLs for sibling deps; install in order with --no-deps.
RUN chmod +x /tmp/install-monorepo-editables.sh \
    && if [ "${INSTALL_MONOREPO_EDITABLES}" = "1" ]; then \
      NORNIR_MONOREPO_ROOT=/opt/nornir /tmp/install-monorepo-editables.sh; \
    else \
      rm -rf ./nornir-shared ./nornir-pools ./nornir-imageregistration ./dm4 ./nornir-buildmanager; \
    fi \
    && rm -f /tmp/install-monorepo-editables.sh

# Dev/test tooling (not in prod image)
RUN pip install --no-cache-dir pytest

COPY nornir-docker/cursor-dev-entry.sh /usr/local/bin/cursor-dev-entry.sh
COPY nornir-docker/install-monorepo-editables.sh /usr/local/bin/install-monorepo-editables.sh
COPY nornir-docker/mount-network-shares.sh /usr/local/bin/mount-network-shares.sh
COPY nornir-docker/drop-sys-admin-after-mounts.sh /usr/local/bin/drop-sys-admin-after-mounts.sh
RUN sed -i 's/\r$//' /usr/local/bin/cursor-dev-entry.sh \
    && sed -i 's/\r$//' /usr/local/bin/install-monorepo-editables.sh \
    && sed -i 's/\r$//' /usr/local/bin/mount-network-shares.sh \
    && sed -i 's/\r$//' /usr/local/bin/drop-sys-admin-after-mounts.sh \
    && chmod +x /usr/local/bin/cursor-dev-entry.sh /usr/local/bin/install-monorepo-editables.sh \
       /usr/local/bin/mount-network-shares.sh /usr/local/bin/drop-sys-admin-after-mounts.sh

# Repro corpus mount point; populated at run time via compose (see INPUT_NORNIR_DATA, /data bind).
RUN mkdir -p /data

# Interactive login welcome: nornir-build usage + ~/scripts entry wrappers.
RUN printf '%s\n' \
    '' \
    '# Nornir welcome (interactive shells only)' \
    'case "$-" in' \
    '  *i*)' \
    '    if [[ -d "${HOME}/scripts" ]]; then' \
    '      echo ""' \
    '      echo "Nornir"' \
    '      echo "  nornir-build <volume_path> <Pipeline> [args...]"' \
    '      echo "  nornir-build --help"' \
    '      echo ""' \
    '      echo "Scripts in ~/scripts (on PATH):"' \
    '      for _nornir_script in "${HOME}"/scripts/TEM*; do' \
    '        [[ -e "${_nornir_script}" && -x "${_nornir_script}" ]] || continue' \
    '        echo "  $(basename "${_nornir_script}")"' \
    '      done' \
    '      unset _nornir_script' \
    '      echo ""' \
    '    fi' \
    '    ;;' \
    'esac' \
    >> /root/.bashrc

# Final cache-busting stamp: re-declare ARGs so a new BUILD_DATE/SOURCE_REVISION always
# produces a new top layer and image digest even when package COPY layers are cached.
ARG NORNIR_RELEASE=0.0.0-dev
ARG SOURCE_REVISION=unknown
ARG BUILD_DATE=unknown
RUN printf '%s\n' \
        "release=${NORNIR_RELEASE}" \
        "revision=${SOURCE_REVISION}" \
        "built=${BUILD_DATE}" \
        > /etc/nornir-image-info \
    && chmod 644 /etc/nornir-image-info

WORKDIR /workspace
CMD ["bash"]
