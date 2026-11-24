#!/usr/bin/env bash
# Copyright 2026, Leia Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Package the Leia conversion provider as a Debian package.
#
#   ./scripts/package_deb.sh                        # build (scripts/build-linux.sh) + package
#   ./scripts/package_deb.sh --no-build             # package an existing $BUILD_DIR
#   ./scripts/package_deb.sh --allow-no-look-around # permit a provider built against headers
#                                                   # without NeurD_convert_stream_cpu_ex
#
# Output: dist/displayxr-leia-conversion_<ver>_<arch>.deb
#
# ONE package for Ubuntu 22.04, 24.04 and 26.04: build it on the OLDEST of the
# three (an ubuntu:22.04 container; CI does this) and set DXR_DEB_MAX_GLIBC to
# that release's glibc (2.35), so a package built on anything newer fails here
# instead of shipping. scripts/verify_deb_install_linux.sh is the install-side
# check.
#
# Payload (installed layout), in the runtime's built-in discovery root:
#   /usr/lib/displayxr/plugins/DisplayXR-LeiaConversion.so
#   /usr/lib/displayxr/plugins/050-leia-conversion-conversion-provider.json
#
# No maintainer scripts: the package only drops files the runtime discovers.
#
# --- NeurD is an external prerequisite, not a dependency ----------------------
# The provider loads NO NeurD symbol at link time: it finds libNeurD.so at run
# time (NeurDPath setting -> /opt/immersity/neurd-runtime -> NEURD_PATH ->
# LD_LIBRARY_PATH -> ~/.local/share/LeiaInc/NeurD-Runtime) and dlopens it. So
# the .deb carries no relation to NeurD, not even a Recommends: the NeurD
# runtime package is in no Ubuntu archive, and the install check verifies that
# every relation resolves there. Without NeurD the provider reports ABSENT and
# the runtime's conversion falls through to the next provider. This script
# refuses a provider that links libNeurD, exports anything but
# xrtConversionPluginNegotiate, or (without --allow-no-look-around) was built
# against headers that predate NeurD_convert_stream_cpu_ex.
#
# --- Taking the files over from displayxr-leia-sr -------------------------------
# displayxr-leia-sr releases BEFORE $LEIA_SR_SPLIT_VERSION shipped these two
# files themselves. Debian policy 7.6.1 (a file moves between packages):
#   Replaces: displayxr-leia-sr (<< SPLIT~)  dpkg may overwrite that package's copies;
#   Breaks:   displayxr-leia-sr (<< SPLIT~)  and such a version cannot stay installed
#                                            next to this package, so removing or
#                                            reinstalling it can never take the files
#                                            (or the provider) away again.
# The consequence is the install order on a box that has an older displayxr-leia-sr:
# upgrade it in the same transaction (`apt install ./displayxr-leia-conversion_*.deb
# ./displayxr-leia-sr_*.deb`), or apt refuses. LEIA_SR_SPLIT_VERSION must be the
# first displayxr-leia-sr release WITHOUT the provider; set it when that release
# is cut (docs/installer.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build-deb}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
PKG="displayxr-leia-conversion"
# First displayxr-leia-sr release that no longer ships the provider (see above).
LEIA_SR_SPLIT_VERSION="${LEIA_SR_SPLIT_VERSION:-2.24.0}"
# First runtime with the conversion-provider ABI (CMake DXR_CONV_MIN_RUNTIME_VERSION).
MIN_RUNTIME_VERSION="$(sed -nE 's/^set\(DXR_CONV_MIN_RUNTIME_VERSION[[:space:]]+"([^"]+)".*/\1/p' "$ROOT/CMakeLists.txt")"
[ -n "$MIN_RUNTIME_VERSION" ] || { echo "error: DXR_CONV_MIN_RUNTIME_VERSION not found in CMakeLists.txt" >&2; exit 1; }

NO_BUILD=0
ALLOW_NO_LOOK_AROUND=0
for arg in "$@"; do
    case "$arg" in
    --no-build) NO_BUILD=1 ;;
    --allow-no-look-around) ALLOW_NO_LOOK_AROUND=1 ;;
    *) echo "Unknown option: $arg (supported: --no-build --allow-no-look-around)" >&2; exit 2 ;;
    esac
done

for tool in dpkg-deb dpkg-shlibdeps patchelf objdump nm strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found (apt install dpkg-dev patchelf binutils)." >&2; exit 1; }
done

find_so() { find "$BUILD_DIR" -name "DisplayXR-LeiaConversion.so" -type f 2>/dev/null | head -1; }

if [ "$NO_BUILD" = 0 ]; then
    echo "==> Building (Release) into $BUILD_DIR"
    BUILD_DIR="$BUILD_DIR" CMAKE_BUILD_TYPE=Release "$ROOT/scripts/build-linux.sh"
fi
SO="$(find_so)"
[ -n "$SO" ] || { echo "error: DisplayXR-LeiaConversion.so not found under $BUILD_DIR." >&2; exit 1; }

# Version: git describe -> Debian-legal upstream version (the runtime's rule).
RAW="$(git -C "$ROOT" describe --tags --always --dirty --match 'v[0-9]*' 2>/dev/null || echo 0.0.0)"
VERSION="${DXR_DEB_VERSION:-$(echo "$RAW" | sed -e 's/^v//' -e 's/-dirty$/+dirty/' -e 's/-\([0-9]\+\)-g/+\1.g/')}"
case "$VERSION" in [0-9]*) : ;; *) VERSION="0.0.0+g$VERSION" ;; esac
ARCH="$(dpkg --print-architecture)"

STAGE="$DIST_DIR/${PKG}_${VERSION}_${ARCH}"
echo "==> Staging $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/lib/displayxr/plugins"

STAGED="$STAGE/usr/lib/displayxr/plugins/DisplayXR-LeiaConversion.so"
install -m 0644 "$SO" "$STAGED"
# No build-machine path may ship in the ELF.
patchelf --remove-rpath "$STAGED"

needed="$(objdump -p "$STAGED" | awk '/NEEDED/{print $2}')"
if grep -qi neurd <<<"$needed"; then
    echo "error: $SO links NeurD at load time; it must only dlopen libNeurD.so (no NeurD dependency)." >&2
    exit 1
fi
syms="$(nm -D --defined-only "$STAGED" | awk '{print $NF}')"
if [ "$syms" != "xrtConversionPluginNegotiate" ]; then
    echo "error: $SO must export exactly xrtConversionPluginNegotiate, exports: $syms" >&2
    exit 1
fi
# Look-around gate: this log text sits inside the provider's
# DXR_LEIA_NEURD_HAS_CPU_EX code, so it is compiled in only when the headers
# declare NeurD_convert_stream_cpu_ex. Captured, not piped: `strings | grep -q`
# under pipefail fails on the SIGPIPE even when grep matched.
all_strings="$(strings "$STAGED")"
if grep -qF 'NeurD_convert_stream_cpu_ex -> ' <<<"$all_strings"; then
    echo "==> NeurD_convert_stream_cpu_ex compiled in (look-around)"
elif [ "$ALLOW_NO_LOOK_AROUND" = 1 ]; then
    echo "==> WARNING: built WITHOUT NeurD_convert_stream_cpu_ex: fixed pair, no look-around"
    echo "    (--allow-no-look-around set). Do not release it."
else
    echo "error: $SO was built against NeurD headers without NeurD_convert_stream_cpu_ex, so" >&2
    echo "       Convert to 3D would ship without look-around. Fetch headers that have it" >&2
    echo "       (scripts/neurd-pins.env, NEURD_SDK_REF_LINUX) or pass --allow-no-look-around." >&2
    exit 1
fi

MANIFEST="$STAGE/usr/lib/displayxr/plugins/050-leia-conversion-conversion-provider.json"
cat > "$MANIFEST" <<JSON
{
    "file_format_version": "1.0",
    "plugin": {
        "id":           "leia-conversion",
        "display_name": "Leia conversion",
        "vendor":       "Leia Inc.",
        "version":      "$VERSION",
        "binary_path":  "/usr/lib/displayxr/plugins/DisplayXR-LeiaConversion.so",
        "probe_order":  50
    }
}
JSON
chmod 0644 "$MANIFEST"
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANIFEST" ||
        { echo "error: the manifest is not valid JSON" >&2; exit 1; }
fi

# --- Depends: one .deb for Ubuntu 22.04, 24.04 and 26.04 ----------------------
# Two independent failure modes, both checked here (the runtime's #1656 fix):
#  1. The glibc / libstdc++ floor is the build host's, so the package is built
#     on the oldest supported release and dpkg-shlibdeps turns the symbol
#     versions the .so references into VERSIONED Depends; DXR_DEB_MAX_GLIBC
#     makes a floor above the oldest release a hard error.
#  2. A library's PACKAGE NAME is not stable across releases, so every
#     DT_NEEDED must be on STABLE_SONAMES ("the name dpkg-shlibdeps derives on
#     the oldest release resolves on all three"). A newly linked library fails
#     here instead of narrowing where the package installs.
STABLE_SONAMES=(
    libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1
    ld-linux-x86-64.so.2 ld-linux-aarch64.so.1
    libstdc++.so.6 libgcc_s.so.1
    libcjson.so.1                   # libcjson1 (the runtime's aux_util; same name on all three)
)
bad=""
for so in $needed; do
    ok=0
    for s in "${STABLE_SONAMES[@]}"; do [ "$so" = "$s" ] && ok=1 && break; done
    [ "$ok" = 1 ] || bad="$bad $so"
done
if [ -n "$bad" ]; then
    echo "error: DT_NEEDED on libraries not known to resolve under one package name" >&2
    echo "       across Ubuntu 22.04/24.04/26.04:$bad" >&2
    echo "       Drop the dependency, link it statically, or add it to STABLE_SONAMES once" >&2
    echo "       the install check proves the 22.04-derived name resolves on all three." >&2
    exit 1
fi

SHLIBS_TMP="$(mktemp -d)"
mkdir -p "$SHLIBS_TMP/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$PKG" "$PKG" >"$SHLIBS_TMP/debian/control"
LIB_DEPENDS="$(cd "$SHLIBS_TMP" && dpkg-shlibdeps -O "$STAGED" | sed -n 's/^shlibs:Depends=//p')"
rm -rf "$SHLIBS_TMP"
[ -n "$LIB_DEPENDS" ] || { echo "error: dpkg-shlibdeps produced no Depends." >&2; exit 1; }
DEPENDS="displayxr-runtime (>= $MIN_RUNTIME_VERSION), $LIB_DEPENDS"
echo "==> Depends: $DEPENDS"

GLIBC_FLOOR="$(objdump -T "$STAGED" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"
GLIBCXX_FLOOR="$(objdump -T "$STAGED" | grep -o 'GLIBCXX_[0-9.]*' | sed 's/GLIBCXX_//' | sort -uV | tail -1)"
echo "==> glibc floor: GLIBC_$GLIBC_FLOOR, GLIBCXX_${GLIBCXX_FLOOR:-none}"
if [ -n "${DXR_DEB_MAX_GLIBC:-}" ] &&
    [ "$(printf '%s\n%s\n' "$GLIBC_FLOOR" "$DXR_DEB_MAX_GLIBC" | sort -V | tail -1)" != "$DXR_DEB_MAX_GLIBC" ]; then
    echo "error: the provider needs GLIBC_$GLIBC_FLOOR, above DXR_DEB_MAX_GLIBC=$DXR_DEB_MAX_GLIBC" >&2
    echo "       (the oldest supported release). Build the .deb on that release." >&2
    exit 1
fi

SPLIT_REL="displayxr-leia-sr (<< ${LEIA_SR_SPLIT_VERSION}~)"
echo "==> Replaces / Breaks: $SPLIT_REL"

INSTALLED_KB="$(du -sk "$STAGE/usr" | cut -f1)"
cat > "$STAGE/DEBIAN/control" <<EOF_CONTROL
Package: $PKG
Version: $VERSION
Section: libs
Priority: optional
Architecture: $ARCH
Depends: $DEPENDS
Replaces: $SPLIT_REL
Breaks: $SPLIT_REL
Installed-Size: $INSTALLED_KB
Maintainer: Leia Inc / The DisplayXR Project <noreply@displayxr.dev>
Description: DisplayXR Leia conversion provider (2D to 3D)
 The Leia conversion provider for the DisplayXR OpenXR runtime: Convert to 3D
 with views that follow the tracked viewer. Drops into the runtime's built-in
 plug-in directory (/usr/lib/displayxr/plugins) with the vendor probe order
 (50).
 .
 The Leia conversion runtime is not a dependency and is not part of this
 package: the provider loads it at run time when it is installed and declines
 without it, so the runtime uses its next conversion provider instead. The
 Leia conversion runtime has its own installer.
 .
 Replaces the copy of the provider that displayxr-leia-sr shipped before
 version $LEIA_SR_SPLIT_VERSION.
EOF_CONTROL

mkdir -p "$DIST_DIR"
DEB="$DIST_DIR/${PKG}_${VERSION}_${ARCH}.deb"
if command -v fakeroot >/dev/null 2>&1; then
    fakeroot dpkg-deb --build --root-owner-group "$STAGE" "$DEB"
else
    dpkg-deb --build --root-owner-group "$STAGE" "$DEB"
fi

echo ""
echo "==> $DEB"
dpkg-deb --info "$DEB" | sed 's/^/    /'
echo "    --- contents ---"
dpkg-deb --contents "$DEB" | sed 's/^/    /'
exit 0
