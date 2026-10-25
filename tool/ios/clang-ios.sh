#!/bin/bash
# Wraps the iOS SDK clang so cgo sees the device sysroot, the arm64 slice and
# a deployment target that matches the Xcode project.
#
# Go invokes CC as a single program, so the flags live here rather than in an
# environment variable: CGO_CFLAGS alone does not reach the linker step.
set -euo pipefail

SDK="${IOS_SDK:-iphoneos}"
MIN_VERSION="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"

exec xcrun --sdk "$SDK" clang \
  -arch arm64 \
  -isysroot "$SYSROOT" \
  -miphoneos-version-min="$MIN_VERSION" \
  "$@"
