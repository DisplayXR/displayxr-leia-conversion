#!/usr/bin/env bash
# Copyright 2026, Leia Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Install-verify the provider .deb on a CLEAN Ubuntu release. Run it as root
# inside a pristine ubuntu:<release> container (CI's DebInstall matrix does this
# for 22.04, 24.04 and 26.04); locally:
#
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:22.04 \
#     ./scripts/verify_deb_install_linux.sh dist/displayxr-leia-conversion_*.deb \
#                                           runtime-deb/displayxr-runtime_*.deb
#
# The runtime .deb is passed alongside because the provider Depends on it; apt
# installs both from the same command, so an unsatisfiable dependency in either
# one fails here.
#
# Fails if:
#   * apt cannot resolve the package's Depends from that release's archive
#     (installed with --no-install-recommends: Depends alone must be enough);
#   * a Depends / Recommends / Suggests name does not exist on that release;
#   * `ldd -r` on the installed provider reports a missing library, symbol or
#     symbol version, or names NeurD (it must only dlopen it);
#   * the discovery manifest is missing or does not point at the installed .so;
#   * the package does not declare the Replaces / Breaks that take the files over
#     from displayxr-leia-sr;
#   * (with a runtime that has it) `displayxr-cli conv list` does not list
#     leia-conversion. Without NeurD on the box the provider reports ABSENT;
#     that is the expected state here, not a failure.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <displayxr-leia-conversion.deb> [displayxr-runtime.deb]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "error: run as root in a throwaway container." >&2; exit 2; }

DEBS=()
for d in "$@"; do DEBS+=("$(readlink -f "$d")"); done
# shellcheck disable=SC1091
. /etc/os-release
echo "==> $PRETTY_NAME: installing ${DEBS[*]##*/}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends "${DEBS[@]}"

PKG=displayxr-leia-conversion
dpkg-query -W -f='==> installed ${Package} ${Version}\n    Depends: ${Depends}\n    Replaces: ${Replaces}\n    Breaks: ${Breaks}\n' "$PKG"

fail=0

for field in Depends Recommends Suggests; do
    for p in $(dpkg-query -W -f="\${$field}" "$PKG" | tr ',|' '\n\n' | sed 's/(.*)//; s/:any//; s/ //g' | sed '/^$/d'); do
        if apt-cache show "$p" >/dev/null 2>&1 || dpkg-query -W "$p" >/dev/null 2>&1; then
            echo "    $field $p: available"
        else
            echo "error: $field '$p' does not exist on $PRETTY_NAME." >&2
            fail=1
        fi
    done
done

for field in Replaces Breaks; do
    v="$(dpkg-query -W -f="\${$field}" "$PKG")"
    case "$v" in
    "displayxr-leia-sr (<< "*) echo "    $field: $v" ;;
    *) echo "error: $field is '$v'; expected 'displayxr-leia-sr (<< <split version>~)'." >&2; fail=1 ;;
    esac
done

SO=/usr/lib/displayxr/plugins/DisplayXR-LeiaConversion.so
MANIFEST=/usr/lib/displayxr/plugins/050-leia-conversion-conversion-provider.json
[ -f "$SO" ] || { echo "error: $SO not installed." >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "error: $MANIFEST not installed." >&2; fail=1; }
grep -q "$SO" "$MANIFEST" || { echo "error: $MANIFEST does not point at $SO." >&2; fail=1; }
[ "$(dpkg-query -S "$SO" | cut -d: -f1)" = "$PKG" ] || { echo "error: $SO is not owned by $PKG." >&2; fail=1; }

out="$(ldd -r "$SO" 2>&1)" || true
echo "$out" | sed 's/^/    /'
if grep -E 'not found|undefined symbol' <<<"$out"; then
    echo "error: unresolved dependency in $SO on $PRETTY_NAME." >&2
    fail=1
elif grep -qi neurd <<<"$out"; then
    echo "error: $SO loads NeurD at link time (must dlopen it)." >&2
    fail=1
else
    echo "    ldd -r $SO: ok (no NeurD dependency)"
fi

if command -v displayxr-cli >/dev/null 2>&1; then
    unset XR_RUNTIME_JSON XRT_PLUGIN_SEARCH_PATH
    # Captured, not piped: `cmd | grep -q` under pipefail fails on grep's SIGPIPE.
    if conv_out="$(displayxr-cli conv list 2>&1)"; then
        echo "$conv_out" | sed 's/^/    /'
        if grep -q 'leia-conversion' <<<"$conv_out"; then
            echo "    displayxr-cli conv list: leia-conversion is discovered"
        else
            echo "error: displayxr-cli conv list does not list leia-conversion on $PRETTY_NAME." >&2
            fail=1
        fi
    else
        echo "$conv_out" | sed 's/^/    /'
        echo "    note: this runtime's displayxr-cli has no working 'conv list' here; discovery not checked."
    fi
else
    echo "    note: displayxr-cli not installed (no runtime .deb passed); discovery not checked."
fi

[ "$fail" = 0 ] || { echo "==> FAIL on $PRETTY_NAME" >&2; exit 1; }
echo "==> PASS on $PRETTY_NAME"
