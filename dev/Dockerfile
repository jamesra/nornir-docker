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
ARG CUPY_PACKAGE=cupy-cuda13x

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
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgl1 libosmesa6 \
    && rm -rf /var/lib/apt/lists/*

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    NORNIR_HEADLESS=1 \
    PYOPENGL_PLATFORM=osmesa

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --upgrade pip setuptools wheel

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

# Local pyprojects reference git URLs for sibling deps; install in order with --no-deps.
RUN if [ "${INSTALL_MONOREPO_EDITABLES}" = "1" ]; then \
      pip install --no-cache-dir -e ./nornir-shared \
      && pip install --no-cache-dir -e ./nornir-pools \
      && pip install --no-cache-dir -e ./nornir-imageregistration \
      && pip install --no-cache-dir -e ./dm4 \
      && pip install --no-cache-dir -e ./nornir-buildmanager; \
    else \
      rm -rf ./nornir-shared ./nornir-pools ./nornir-imageregistration ./dm4 ./nornir-buildmanager; \
    fi

# Dev/test tooling (not in prod image)
RUN pip install --no-cache-dir pytest

COPY nornir-docker/cursor-dev-entry.sh /usr/local/bin/cursor-dev-entry.sh
RUN sed -i 's/\r$//' /usr/local/bin/cursor-dev-entry.sh \
    && chmod +x /usr/local/bin/cursor-dev-entry.sh

WORKDIR /workspace
CMD ["bash"]
