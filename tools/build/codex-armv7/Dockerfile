FROM rust:1.95-bookworm@sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      binutils \
      build-essential \
      ca-certificates \
      clang \
      cmake \
      file \
      git \
      ninja-build \
      patch \
      perl \
      pkg-config \
      python3 \
    && rm -rf /var/lib/apt/lists/*

RUN rustup target add \
      --toolchain 1.95.0-x86_64-unknown-linux-gnu \
      armv7-unknown-linux-gnueabihf \
    && rustup component add \
      --toolchain 1.95.0-x86_64-unknown-linux-gnu \
      rustfmt \
    && test ! -e \
      /usr/local/rustup/toolchains/1.95.0-x86_64-unknown-linux-gnu/lib/rustlib/src/rust

WORKDIR /src/codex-rs

# Keep the recipe identity in the final metadata-only layer so edits to the
# mounted build script or patches do not invalidate the pinned toolchain layer.
ARG PLUTO_CODEX_RECIPE_DIGEST
LABEL dev.pluto.codex-armv7.recipe-digest="${PLUTO_CODEX_RECIPE_DIGEST}"
