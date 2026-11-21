#!/usr/bin/env bash
# Copyright 2026, Leia Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Build + validate the Linux arm of the Leia conversion provider
# (DisplayXR-LeiaConversion.so, CPU transport).
#
#   ./scripts/build-linux.sh [--no-test] [--clean] [--pure]
#
#   --pure   only the pure layers and their tests (no runtime, no NeurD headers)
#
# Environment:
#   DXR_RUNTIME_SOURCE_DIR  local displayxr-runtime checkout (default:
#                           ../displayxr-runtime). Unset and absent: CMake
#                           fetches the pinned tag (network).
#   NEURD_SDK_ROOT          dir with include/NeurD.h etc. Default:
#                           NeurD-SDK-<NEURD_SDK_REF_LINUX>/ in this repo, fetched
#                           with scripts/fetch-neurd-headers.sh when missing
#                           (needs gh / GH_TOKEN with read access to media_sdk).
#   BUILD_DIR               default: build/
#
# What it checks after the build: every ctest (the pure tests, the ABSENT /
# DISABLED gates, describe_settings, and with cpu_ex headers the NeurD
# function-table guard against the fake libNeurD.so builds), that the .so
# exports exactly xrtConversionPluginNegotiate, has no unresolved symbol and
# no NeurD DT_NEEDED.
#
# Debian/Ubuntu deps: see .github/workflows/build-linux.yml (same list).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

RUN_TEST=1
PURE=0
for arg in "$@"; do
    case "$arg" in
    --no-test) RUN_TEST=0 ;;
    --clean) rm -rf "$BUILD_DIR" ;;
    --pure) PURE=1 ;;
    *)
        echo "Unknown option: $arg (supported: --no-test --clean --pure)" >&2
        exit 2
        ;;
    esac
done

if [ "$PURE" = 1 ]; then
    cmake -S "$ROOT" -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DDXR_CONV_PURE_TESTS_ONLY=ON
    cmake --build "$BUILD_DIR"
    [ "$RUN_TEST" = 0 ] || ctest --test-dir "$BUILD_DIR/src" --output-on-failure
    exit 0
fi

# shellcheck source=scripts/neurd-pins.env
. "$ROOT/scripts/neurd-pins.env"

if [ -z "${NEURD_SDK_ROOT:-}" ]; then
    NEURD_SDK_ROOT="$ROOT/NeurD-SDK-$NEURD_SDK_REF_LINUX"
    if [ ! -f "$NEURD_SDK_ROOT/include/NeurD_version.h" ]; then
        echo "==> Fetching NeurD headers ($NEURD_SDK_REPO@$NEURD_SDK_REF_LINUX)"
        "$ROOT/scripts/fetch-neurd-headers.sh" "$NEURD_SDK_REPO" "$NEURD_SDK_REF_LINUX" "$NEURD_SDK_ROOT" || {
            echo "error: no NeurD headers; the provider cannot be built. Use --pure for the pure tests." >&2
            exit 1
        }
    fi
fi

RUNTIME_ARGS=()
RUNTIME_DIR="${DXR_RUNTIME_SOURCE_DIR:-$(cd "$ROOT/.." && pwd)/displayxr-runtime}"
if [ -f "$RUNTIME_DIR/CMakeLists.txt" ]; then
    RUNTIME_ARGS=(-DDXR_RUNTIME_SOURCE_DIR="$RUNTIME_DIR")
    echo "==> Configuring (runtime: $RUNTIME_DIR; NeurD headers: $NEURD_SDK_ROOT)"
else
    echo "==> Configuring (runtime: fetched at the pinned tag; NeurD headers: $NEURD_SDK_ROOT)"
fi
cmake -S "$ROOT" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Debug}" \
    -DDXR_CONV_REQUIRE_PROVIDER=ON \
    -DNEURD_SDK_ROOT="$NEURD_SDK_ROOT" \
    "${RUNTIME_ARGS[@]}"

echo "==> Building"
cmake --build "$BUILD_DIR"

SO="$BUILD_DIR/src/DisplayXR-LeiaConversion.so"
[ -f "$SO" ] || { echo "error: $SO not built" >&2; exit 1; }

echo "==> Provider: single export, no unresolved symbols, no NeurD link dependency"
SYMS="$(nm -D --defined-only "$SO" | awk '{print $NF}')"
if [ "$SYMS" != "xrtConversionPluginNegotiate" ]; then
    echo "error: unexpected exported symbols in $SO:" >&2
    nm -D --defined-only "$SO" >&2
    exit 1
fi
if ldd -r "$SO" 2>&1 | grep -q 'undefined symbol'; then
    echo "error: unresolved symbols in $SO" >&2
    ldd -r "$SO" >&2
    exit 1
fi
if objdump -p "$SO" | awk '/NEEDED/{print $2}' | grep -qi neurd; then
    echo "error: $SO links NeurD at load time; it must only dlopen libNeurD.so." >&2
    exit 1
fi
echo "    OK: $SO"

if [ "$RUN_TEST" = 1 ]; then
    # build/src only: with a fetched runtime and CMake < 3.28 the runtime's own
    # tests are registered in the same tree, and they are not this repo's to run.
    echo "==> ctest"
    ctest --test-dir "$BUILD_DIR/src" --output-on-failure
fi
