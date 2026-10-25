#!/bin/bash
# Builds the FlClash mihomo core as an iOS c-archive.
#
# Two archives, because the two processes that link the core live under
# different budgets:
#
#   libclash.a          app process  (config building, delay tests, probing)
#   libclash_lowmem.a   packet-tunnel extension, built with the `lowmem` tag so
#                       the governor starts from a 48MB ceiling and a 30% GC
#                       target instead of waiting for a caller to set one.
#
# The Xcode project links each archive into its own target and reads the
# generated headers, so both must exist before xcodebuild resolves them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/libclash/ios/arm64"

if [ "${PLATFORM_NAME:-iphoneos}" != "iphoneos" ]; then
  echo "build_core: skipping core build for platform '${PLATFORM_NAME:-unknown}'"
  exit 0
fi

if ! command -v go >/dev/null 2>&1; then
  echo "build_core: go is not on PATH" >&2
  exit 1
fi

mkdir -p "$OUT"

export CGO_ENABLED=1
export GOOS=ios
export GOARCH=arm64
export CC="$ROOT/tool/ios/clang-ios.sh"
export CGO_CFLAGS="-O2 -fPIC"
export CGO_LDFLAGS="-fuse-ld=ld"

build() {
  local name="$1"
  local tags="$2"
  local archive="$OUT/$name.a"

  echo "build_core: building $name (tags='$tags')"
  (
    cd "$ROOT/core"
    # -trimpath keeps the archive reproducible; -buildvcs=false because the
    # build runs inside a git worktree owned by Xcode.
    go build \
      -trimpath \
      -buildvcs=false \
      -buildmode=c-archive \
      -tags "$tags" \
      -o "$archive" \
      ./cmd/ios
  )

  # c-archive writes <archive>.h next to the library and the ObjC bridges
  # import it as libclash.h / libclash_lowmem.h.
  if [ ! -f "$OUT/$name.h" ]; then
    echo "build_core: expected header $OUT/$name.h" >&2
    exit 1
  fi
  # The generated header carries the cgo preamble, which quotes bride.h; a
  # quoted include resolves next to the including file, so the callback table
  # has to sit beside both headers.
  cp "$ROOT/core/bride.h" "$OUT/bride.h"
  ls -lh "$archive" "$OUT/$name.h"
}

build libclash "ios,cgo"
build libclash_lowmem "ios,cgo,lowmem"

echo "build_core: done"
