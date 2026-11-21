#!/usr/bin/env bash
# Copyright 2026, Leia Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Test the .deb's takeover of the provider files from displayxr-leia-sr
# (Replaces / Breaks, scripts/package_deb.sh). Run as root in a THROWAWAY
# container; it installs and removes packages.
#
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:22.04 \
#     ./scripts/test_deb_handover.sh dist/displayxr-leia-conversion_*.deb
#
# It builds three stand-in packages with dpkg-deb (no real payload):
#   displayxr-runtime 99.0.0        satisfies the provider's Depends
#   displayxr-leia-sr <old>         BEFORE the split: ships the two provider files
#   displayxr-leia-sr <split>       AFTER the split: does not
# where <split> is the version the provider's Breaks names and <old> is below it.
#
# Cases:
#   A  fresh box: the provider installs and owns its files
#   B  old leia-sr installed, the provider alone: REFUSED, the old files untouched
#   C  old leia-sr installed, provider + split leia-sr in one apt transaction:
#      accepted, the files are the provider's and owned by it
#   D  removing leia-sr afterwards leaves the provider's files in place
#   E  the old leia-sr cannot be installed next to the provider
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <displayxr-leia-conversion.deb>" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "error: run as root in a throwaway container." >&2; exit 2; }
CONV="$(readlink -f "$1")"
export DEBIAN_FRONTEND=noninteractive

PKG=displayxr-leia-conversion
SO=/usr/lib/displayxr/plugins/DisplayXR-LeiaConversion.so
MANIFEST=/usr/lib/displayxr/plugins/050-leia-conversion-conversion-provider.json
ARCH="$(dpkg --print-architecture)"

breaks="$(dpkg-deb -f "$CONV" Breaks)"
replaces="$(dpkg-deb -f "$CONV" Replaces)"
echo "==> Breaks: $breaks"
echo "==> Replaces: $replaces"
[ "$breaks" = "$replaces" ] || { echo "FAIL: Breaks and Replaces differ" >&2; exit 1; }
SPLIT="$(sed -nE 's/^displayxr-leia-sr \(<< ([^~)]+)~?\)$/\1/p' <<<"$breaks")"
[ -n "$SPLIT" ] || { echo "FAIL: cannot read the split version from '$breaks'" >&2; exit 1; }
OLD="0.0.1"
dpkg --compare-versions "$OLD" lt "$SPLIT" || { echo "FAIL: $OLD is not below $SPLIT" >&2; exit 1; }
# A build of the commit right before the split release must be covered too.
dpkg --compare-versions "${SPLIT}~rc1" ge "${SPLIT}~" || { echo "FAIL: version ordering" >&2; exit 1; }

T="$(mktemp -d)"
mkdeb() { # name version with_provider_files(0|1)
    local d="$T/$1_$2"
    mkdir -p "$d/DEBIAN" "$d/usr/lib/displayxr/plugins"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: test <t@example.invalid>\nDescription: stand-in for the handover test\n' \
        "$1" "$2" "$ARCH" >"$d/DEBIAN/control"
    echo "$1 $2" >"$d/usr/lib/displayxr/plugins/$1.marker"
    if [ "$3" = 1 ]; then
        echo "OLD leia-sr copy" >"$d/$SO"
        echo '{"old": true}' >"$d/$MANIFEST"
    fi
    dpkg-deb --build --root-owner-group "$d" "$T/$1_$2.deb" >/dev/null
    echo "$T/$1_$2.deb"
}
RT="$(mkdeb displayxr-runtime 99.0.0 0)"
SR_OLD="$(mkdeb displayxr-leia-sr "$OLD" 1)"
SR_NEW="$(mkdeb displayxr-leia-sr "$SPLIT" 0)"

owner() { dpkg-query -S "$1" 2>/dev/null | cut -d: -f1; }
is_provider_so() { ! grep -q 'OLD leia-sr copy' "$SO"; }
reset() { dpkg --purge "$PKG" displayxr-leia-sr >/dev/null 2>&1 || true; }
pass() { echo "    PASS: $*"; }
fail() { echo "    FAIL: $*" >&2; exit 1; }

dpkg -i "$RT" >/dev/null

echo "==> A: fresh box"
reset
dpkg -i "$CONV" >/dev/null
[ "$(owner "$SO")" = "$PKG" ] && [ "$(owner "$MANIFEST")" = "$PKG" ] || fail "files not owned by $PKG"
pass "installed; $SO and the manifest are owned by $PKG"

echo "==> B: old displayxr-leia-sr $OLD installed, the provider alone"
reset
dpkg -i "$SR_OLD" >/dev/null
if dpkg -i "$CONV" >"$T/b.log" 2>&1; then
    cat "$T/b.log"; fail "dpkg accepted the provider next to displayxr-leia-sr $OLD"
fi
grep -qi 'break' "$T/b.log" || { cat "$T/b.log"; fail "refused, but not because of Breaks"; }
[ "$(owner "$SO")" = "displayxr-leia-sr" ] && ! is_provider_so || fail "the old package's file was touched"
pass "refused (Breaks); the old package still owns its untouched copy"
dpkg --remove "$PKG" >/dev/null 2>&1 || true # drop the half-installed state

echo "==> C: old displayxr-leia-sr installed, provider + displayxr-leia-sr $SPLIT together (apt)"
reset
dpkg -i "$SR_OLD" >/dev/null
apt-get install -y -qq --no-install-recommends "$CONV" "$SR_NEW" >"$T/c.log" 2>&1 || { cat "$T/c.log"; fail "apt refused the joint upgrade"; }
[ "$(owner "$SO")" = "$PKG" ] && [ "$(owner "$MANIFEST")" = "$PKG" ] || fail "files not owned by $PKG after the joint upgrade"
is_provider_so || fail "$SO is still the old package's copy"
[ "$(dpkg-query -W -f='${Version}' displayxr-leia-sr)" = "$SPLIT" ] || fail "displayxr-leia-sr was not upgraded"
pass "accepted; the files are the provider's and owned by $PKG"

echo "==> D: removing displayxr-leia-sr afterwards"
dpkg --remove displayxr-leia-sr >/dev/null
[ -f "$SO" ] && [ -f "$MANIFEST" ] && is_provider_so || fail "the provider's files went away with displayxr-leia-sr"
pass "the provider's files stay"

echo "==> E: old displayxr-leia-sr $OLD next to the installed provider"
if dpkg -i "$SR_OLD" >"$T/e.log" 2>&1; then
    cat "$T/e.log"; fail "dpkg accepted displayxr-leia-sr $OLD next to the provider"
fi
is_provider_so && [ "$(owner "$SO")" = "$PKG" ] || fail "the provider's file was overwritten"
pass "refused; the provider's files are intact"

rm -rf "$T"
echo "==> PASS: handover from displayxr-leia-sr (<< $SPLIT)"
