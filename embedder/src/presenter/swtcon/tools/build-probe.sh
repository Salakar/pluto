#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMBEDDER_DIR="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
REPO_ROOT="$(cd "${EMBEDDER_DIR}/.." && pwd)"
BUILD_DIR="${EMBEDDER_DIR}/build/aarch64-probe"
OUT="${BUILD_DIR}/swtcon_probe"
IMAGE="${SWTCON_PROBE_IMAGE:-ubuntu:24.04}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

docker run --rm \
  --platform linux/arm64 \
  -e HOST_UID="${HOST_UID}" \
  -e HOST_GID="${HOST_GID}" \
  -v "${REPO_ROOT}:/workspace" \
  -w /workspace/embedder \
  "${IMAGE}" \
  bash -lc '
    set -euo pipefail
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      file \
      libdrm-dev \
      ninja-build \
      pkg-config \
      binutils
    rm -rf /var/lib/apt/lists/*

    cmake -S . -B build/aarch64-probe -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DPLUTO_BUILD_TESTS=OFF \
      -DPLUTO_BUILD_SWTCON_PROBE=ON
    cmake --build build/aarch64-probe --target swtcon_probe

    file build/aarch64-probe/swtcon_probe
    glibc_max="$(
      readelf --version-info build/aarch64-probe/swtcon_probe |
        sed -n "s/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p" |
        sort -Vu |
        tail -n 1
    )"
    if [ -z "${glibc_max}" ]; then
      echo "unable to determine GLIBC version requirements" >&2
      exit 1
    fi
    echo "GLIBC max: ${glibc_max}"
    if [ "$(printf "%s\n%s\n" "${glibc_max}" "2.39" | sort -V | tail -n 1)" != "2.39" ]; then
      echo "GLIBC requirement ${glibc_max} exceeds 2.39" >&2
      exit 1
    fi
    file build/aarch64-probe/swtcon_probe | grep -Eq "ELF 64-bit.*ARM aarch64"
    chown -R "${HOST_UID}:${HOST_GID}" build/aarch64-probe
  '

printf "output: %s\n" "${OUT}"
