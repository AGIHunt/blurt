#!/bin/bash
# The Linux backend's checks in Docker (Ubuntu 26.04), from any machine with Docker:
#   crates/blurt-remote/ci/linux/run.sh          build the image if needed; cargo check, clippy -D warnings, tests (the encoder
#                                                test runs real x264 + avdec_h264)
# Build output stays in a Docker volume, never in the repository.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"
docker image inspect blurt-remote-linux >/dev/null 2>&1 || docker build -t blurt-remote-linux --target build "$here"
docker run --rm \
  -v "$repo:/src:ro" \
  -v blurt-remote-linux-target:/target -v blurt-remote-linux-cargo:/cargo \
  -w /src/crates/blurt-remote \
  blurt-remote-linux bash -c '
    set -e
    cargo check --all-targets
    cargo clippy --all-targets -- -D warnings
    cargo test -- --test-threads 1
  '
