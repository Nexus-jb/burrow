#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Packages the iOS test programs as a .deb, for running the tests on a
# jailbroken device, rootless (iphoneos-arm64) or RootHide (iphoneos-arm64e):
#
#   scripts/package-tests.sh <build-dir> <version> <out-dir> <universal-dir> [rootless|roothide]
#
# <build-dir> holds one directory per architecture (arm64 and arm64e), each
# with the signed test programs, Burrow built as CydiaSubstrate.framework and
# the loader tests in loader/, and the sample tweak BurrowSampleTweak.dylib.
# <universal-dir> holds the crash probe and its tweak, which go into the
# system's tweak directory with a filter for the probe only.
# After installing the package, run "burrow-tests" in a terminal, or
# "burrow-tests probe" to check burrowd from the Burrow package.

set -eu

if [ "$#" -ne 4 ] && [ "$#" -ne 5 ]; then
    echo "usage: $0 <build-dir> <version> <out-dir> <universal-dir> [rootless|roothide]" >&2
    exit 2
fi

build=$1
version=$2
out=$3
universal=$4
scheme=${5:-rootless}
package=com.nexusjb.burrow-tests
# jb: the jailbreak root as the jailbreak's shell names it. On RootHide the
# shell sees the hidden root as /, while the test programs see the real
# file system, so the script hands them paths through RootHide's jbroot
# command.
case "$scheme" in
    rootless)
        architecture=iphoneos-arm64
        jb=/var/jb
        real="printf %s"
        ;;
    roothide)
        architecture=iphoneos-arm64e
        jb=
        real=jbroot
        ;;
    *)
        echo "unknown scheme: $scheme" >&2
        exit 2
        ;;
esac

if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}([~+][0-9A-Za-z.]+)?$'; then
    echo "invalid version: $version" >&2
    exit 1
fi
architectures="arm64 arm64e"
programs="hook-tests relocation-tests objc-tests substrate-tests frameworks/CydiaSubstrate.framework/CydiaSubstrate loader/loader-tests"
for arch in $architectures; do
    for program in $programs; do
        if [ ! -f "$build/$arch/$program" ]; then
            echo "missing program: $build/$arch/$program" >&2
            exit 1
        fi
    done
done
if [ ! -f "$build/BurrowSampleTweak.dylib" ]; then
    echo "missing sample tweak: $build/BurrowSampleTweak.dylib" >&2
    exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
chmod 0755 "$stage"

libexec="$stage$jb/usr/libexec/burrow-tests"
mkdir -p "$stage$jb/usr/bin" "$stage/DEBIAN"
for arch in $architectures; do
    for program in $programs; do
        mkdir -p "$(dirname "$libexec/$arch/$program")"
        cp "$build/$arch/$program" "$libexec/$arch/$program"
        chmod 0755 "$libexec/$arch/$program"
    done
    # The rest of the loader test set: the loader, test tweaks and targets.
    cp -R "$build/$arch/loader/." "$libexec/$arch/loader/"
done
cp "$build/BurrowSampleTweak.dylib" "$libexec/BurrowSampleTweak.dylib"
chmod 0755 "$libexec/BurrowSampleTweak.dylib"
install -m 0755 "$universal/burrow-crash-probe" "$libexec/burrow-crash-probe"
mkdir -p "$stage$jb/usr/lib/TweakInject"
install -m 0755 "$universal/BurrowCrashProbe.dylib" "$stage$jb/usr/lib/TweakInject/BurrowCrashProbe.dylib"
install -m 0644 tests/safemode/probe/BurrowCrashProbe.plist "$stage$jb/usr/lib/TweakInject/BurrowCrashProbe.plist"

# @JB@ and @REAL@ are filled in below.
cat > "$stage/burrow-tests" <<'SCRIPT'
#!@JB@/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Runs Burrow's tests on this device, built for arm64 and for arm64e.
# "burrow-tests probe" checks burrowd instead.
if [ "${1:-}" = probe ]; then
    if ! command -v burrowctl >/dev/null 2>&1; then
        echo "Install the Burrow package (com.nexusjb.burrow) first."
        exit 1
    fi
    before=$(burrowctl crashes 1)
    echo "Crashing burrow-crash-probe on purpose..."
    @JB@/usr/libexec/burrow-tests/burrow-crash-probe
    i=0
    while [ "$i" -lt 30 ]; do
        sleep 2
        latest=$(burrowctl crashes 1)
        if [ "$latest" != "$before" ] && printf '%s\n' "$latest" | grep -q BurrowCrashProbe; then
            echo "$latest"
            echo "Probe: burrowd logged the crash and blamed the probe tweak"
            exit 0
        fi
        i=$((i + 1))
    done
    echo "Probe: burrowd did not log the crash within 60 seconds"
    burrowctl status
    exit 1
fi
failed=0
total=0
run() {
    total=$((total + 1))
    "$@" || failed=$((failed + 1))
}
# A path as the test programs and dyld see it.
real() {
    @REAL@ "$1"
}
libexec=@JB@/usr/libexec/burrow-tests
uname -m
for arch in arm64 arm64e; do
    dir=$libexec/$arch
    on_disk=$(real "$dir")
    echo "== $arch"
    run "$dir/relocation-tests"
    for mode in direct island adrp abs adrp-far abs-far; do
        run "$dir/hook-tests" "$mode"
    done
    run "$dir/objc-tests"
    # The sample tweak's CydiaSubstrate.framework resolves to Burrow.
    export DYLD_FRAMEWORK_PATH="$on_disk/frameworks"
    run "$dir/substrate-tests" "$(real "$libexec/BurrowSampleTweak.dylib")"
    unset DYLD_FRAMEWORK_PATH
    run "$dir/loader/loader-tests" "$on_disk/loader"
    # Crashes a test program on purpose and reads the crash reports.
    run "$dir/loader/safemode-tests" "$on_disk/loader"
done
if [ "$failed" -eq 0 ]; then
    echo "Burrow tests: all passed"
else
    echo "Burrow tests: $failed of $total programs failed"
    exit 1
fi
SCRIPT
sed -e "s|@JB@|$jb|g" -e "s|@REAL@|$real|g" "$stage/burrow-tests" > "$stage$jb/usr/bin/burrow-tests"
rm "$stage/burrow-tests"
chmod 0755 "$stage$jb/usr/bin/burrow-tests"

cat > "$stage/DEBIAN/control" <<CONTROL
Package: $package
Name: Burrow Tests
Version: $version
Architecture: $architecture
Section: Development
Maintainer: Ultra Team
Author: Ultra Team
Homepage: https://github.com/Nexus-jb/burrow
Description: Test programs for the Burrow hooking engine
 Development builds only. Run burrow-tests in a terminal to check that
 Burrow can hook functions on this device.
CONTROL

mkdir -p "$out"
deb="$out/${package}_${version}_${architecture}.deb"
dpkg-deb -Zxz --root-owner-group --build "$stage" "$deb" >/dev/null
echo "$deb"
