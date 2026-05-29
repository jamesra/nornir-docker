# Build from monorepo root:
#
# CPU-only production (default):
#   docker build -f nornir-docker/prod/Dockerfile -t nornir:prod .
#
# Production + CuPy (same Dockerfile):
#   docker build -f nornir-docker/prod/Dockerfile --build-arg INSTALL_CUPY=1 -t nornir:cupy .
#
# Optional override: --build-arg CUPY_PACKAGE=cupy-cuda12x --build-arg NVIDIA_CUDA_APT_VERSION=12-6 (majors must match).
#
# Headless Nornir stack (no Pyre). Python 3.14 + ImageMagick 7. No pytest (see dev/Dockerfile).

FROM python:3.14-bookworm

ARG NORNIR_RELEASE=0.0.0-dev
ARG SOURCE_REVISION=unknown
ARG BUILD_DATE=unknown
ARG IMAGE_SOURCE=https://github.com/jamesra/nornir
ARG NORNIR_IMAGE_VARIANT=prod
ARG PACKAGE_VERSIONS_JSON_B64=
ARG IMAGE_TITLE=Nornir production image
ARG IMAGE_DESCRIPTION=Headless Nornir production stack for Python 3.14

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
ARG INSTALL_CUPY=0
ARG CUPY_PACKAGE=cupy-cuda13x
ARG NVIDIA_CUDA_APT_VERSION=13-1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        wget ca-certificates autoconf pkg-config build-essential \
        libpng-dev libjpeg62-turbo-dev libopenjp2-7-dev libtiff-dev libxml2-dev \
        zlib1g-dev libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

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

# mosquitto: optional MQTT log broker for nornir_shared.prettyoutput (localhost:1883)
RUN apt-get update \
    && apt-get install -y --no-install-recommends mosquitto mosquitto-clients \
    && rm -rf /var/lib/apt/lists/*

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    NORNIR_HEADLESS=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --upgrade pip setuptools wheel

COPY nornir-docker/install-nvidia-cuda-runtime-apt.sh /tmp/install-nvidia-cuda-runtime-apt.sh

COPY nornir-docker/constraints-headless.txt /tmp/constraints-headless.txt
RUN pip install --no-cache-dir -r /tmp/constraints-headless.txt \
    && rm -f /tmp/constraints-headless.txt

RUN set -eux; \
    if [ "${INSTALL_CUPY}" = "1" ]; then \
        chmod +x /tmp/install-nvidia-cuda-runtime-apt.sh \
        && NVIDIA_CUDA_APT_VERSION="${NVIDIA_CUDA_APT_VERSION}" CUPY_PACKAGE="${CUPY_PACKAGE}" \
           /tmp/install-nvidia-cuda-runtime-apt.sh \
        && pip install --no-cache-dir "${CUPY_PACKAGE}"; \
    fi; \
    rm -f /tmp/install-nvidia-cuda-runtime-apt.sh

WORKDIR /opt/nornir
COPY nornir-shared ./nornir-shared
COPY nornir-pools ./nornir-pools
COPY nornir-imageregistration ./nornir-imageregistration
COPY dm4 ./dm4
COPY nornir-buildmanager ./nornir-buildmanager

RUN pip install --no-cache-dir -e ./nornir-shared \
    && pip install --no-cache-dir -e ./nornir-pools \
    && pip install --no-cache-dir -e ./nornir-imageregistration \
    && pip install --no-cache-dir -e ./dm4 \
    && pip install --no-cache-dir -e ./nornir-buildmanager

# Optional repro corpus mount point when run with a /data bind (INPUT_NORNIR_DATA).
RUN mkdir -p /data

WORKDIR /workspace
CMD ["bash"]
