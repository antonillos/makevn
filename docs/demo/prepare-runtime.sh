#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="$(mktemp -d /tmp/makevn-demo-runtime.XXXXXX)"
cd "$root"
./build-rust-dispatcher.sh >&2
PREFIX="$prefix" BIN_DIR="$prefix/bin" LIBEXEC_DIR="$prefix/libexec/makevn" \
  SHARE_DIR="$prefix/share/makevn" SKILL_DIR="$prefix/share/makevn/skills/makevn" \
  ./install.sh --rust >&2
printf '%s\n' "$prefix"
