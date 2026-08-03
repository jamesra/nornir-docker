#!/usr/bin/env bash
# Install NVIDIA CUDA user-mode runtime libraries from the Debian 12 (bookworm) network repo.
#
# Required:
#   NVIDIA_CUDA_APT_VERSION  Apt metapackage suffix, e.g. 13-3 for package cuda-libraries-13-3
#                            (see https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/).
#
# Optional:
#   CUPY_PACKAGE              If set (e.g. cupy-cuda13x), must match the CUDA major in NVIDIA_CUDA_APT_VERSION.
#
# CuPy wheel vs CUDA: https://docs.cupy.dev/en/stable/install.html
# NVIDIA Debian repo: https://developer.nvidia.com/cuda-downloads?target_os=Linux&target_arch=x86_64&Distribution=Debian&target_version=12&target_type=deb_network
#
# Packages: cuda-libraries-* (runtime) plus cuda-cudart-dev-*, cuda-nvrtc-dev-*, cuda-cccl-* so NVRTC
# can resolve #include <cuda_fp16.h> (CuPy JIT). See CuPy docs on NVRTC / missing headers.
#
set -euo pipefail

: "${NVIDIA_CUDA_APT_VERSION:?NVIDIA_CUDA_APT_VERSION is required (e.g. 13-3)}"

if [[ -n "${CUPY_PACKAGE:-}" ]]; then
  if [[ "${CUPY_PACKAGE}" =~ ^cupy-cuda([0-9]+)x$ ]]; then
    cupy_major="${BASH_REMATCH[1]}"
    apt_major="${NVIDIA_CUDA_APT_VERSION%%-*}"
    if [[ "${cupy_major}" != "${apt_major}" ]]; then
      echo "error: CUPY_PACKAGE=${CUPY_PACKAGE} (CUDA major ${cupy_major}) does not match NVIDIA_CUDA_APT_VERSION=${NVIDIA_CUDA_APT_VERSION} (major ${apt_major})" >&2
      exit 1
    fi
  fi
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates wget gnupg

keyring_deb="cuda-keyring_1.1-1_all.deb"
keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/${keyring_deb}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
wget -q -O "${tmpdir}/${keyring_deb}" "${keyring_url}"
dpkg -i "${tmpdir}/${keyring_deb}"

apt-get update -qq

lib_pkg="cuda-libraries-${NVIDIA_CUDA_APT_VERSION}"
cudart_dev_pkg="cuda-cudart-dev-${NVIDIA_CUDA_APT_VERSION}"
nvrtc_dev_pkg="cuda-nvrtc-dev-${NVIDIA_CUDA_APT_VERSION}"
cccl_pkg="cuda-cccl-${NVIDIA_CUDA_APT_VERSION}"

for p in "${lib_pkg}" "${cudart_dev_pkg}" "${nvrtc_dev_pkg}" "${cccl_pkg}"; do
  if ! apt-cache show "${p}" >/dev/null 2>&1; then
    echo "error: ${p} not found in apt cache (check NVIDIA_CUDA_APT_VERSION)" >&2
    exit 1
  fi
done

# Runtime .so (cuda-libraries) is not enough for CuPy: NVRTC JIT needs CUDA headers (e.g. cuda_fp16.h).
# See https://docs.cupy.dev/en/stable/install.html#cupy-always-raises-cupy-cuda-compiler-compileexception
apt-get install -y --no-install-recommends \
  "${lib_pkg}" \
  "${cudart_dev_pkg}" \
  "${nvrtc_dev_pkg}" \
  "${cccl_pkg}"

ldconfig

if ! find /usr/local -name cuda_fp16.h -print -quit 2>/dev/null | grep -q .; then
  echo "error: cuda_fp16.h not found under /usr/local after CUDA dev package install (NVRTC will fail)" >&2
  exit 1
fi
apt-get clean
rm -rf /var/lib/apt/lists/*
