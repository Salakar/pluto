#!/usr/bin/env bash
# Cross-build the QTFB display diagnostic for the Paper Pro Move (aarch64, glibc 2.39).
# The ubuntu:24.04 image (linux/arm64) IS aarch64 with glibc 2.39 — so we compile
# NATIVELY inside it (no cross-toolchain) and get an exact-match ELF.
# Asserts the binary's max required GLIBC symbol version is <= 2.39.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/aarch64
IMAGE="ubuntu:24.04"

docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w "$IMAGE" bash -euo pipefail -c '
  apt-get update -qq && apt-get install -y -qq build-essential binutils file >/dev/null
  gcc -O2 -mcpu=cortex-a55 -Wall -Wextra -std=c11 \
      src/qtfb-probe.c -o build/aarch64/qtfb-probe -lrt
  echo "=== file ==="; file build/aarch64/qtfb-probe
  echo "=== max GLIBC symbol version required ==="
  MAXG=$(objdump -T build/aarch64/qtfb-probe 2>/dev/null | grep -oE "GLIBC_[0-9]+\.[0-9]+" | sort -V | tail -1)
  echo "max=$MAXG"
  # assert <= 2.39 using pure-shell version sort (no python in the base image)
  HIGHEST=$(printf "%s\nGLIBC_2.39\n" "$MAXG" | sort -V | tail -1)
  if [ "$HIGHEST" = "GLIBC_2.39" ]; then
    echo "GLIBC gate: PASS (${MAXG} <= 2.39)"
  else
    echo "GLIBC gate: FAIL (${MAXG} > 2.39)"; exit 1
  fi
'
echo "built: build/aarch64/qtfb-probe"
