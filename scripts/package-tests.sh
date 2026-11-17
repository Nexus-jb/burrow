#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Packages the iOS test programs as a rootless .deb, for running the tests
# on a jailbroken device:
#
#   scripts/package-tests.sh <build-dir> <version> <out-dir>
#
# <build-dir> holds the signed hook-tests and relocation-tests programs.
# After installing the package, run "burrow-tests" in a terminal.

set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <build-dir> <version> <out-dir>" >&2
    exit 2
fi

build=$1
version=$2
out=$3
package=com.nexusjb.burrow-tests
architecture=iphoneos-arm64

if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}([~+][0-9A-Za-z.]+)?$'; then
    echo "invalid version: $version" >&2
    exit 1
fi
for program in hook-tests relocation-tests; do
    if [ ! -x "$build/$program" ]; then
        echo "missing program: $build/$program" >&2
        exit 1
    fi
done

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
chmod 0755 "$stage"

libexec="$stage/var/jb/usr/libexec/burrow-tests"
mkdir -p "$libexec" "$stage/var/jb/usr/bin" "$stage/DEBIAN"
cp "$build/hook-tests" "$build/relocation-tests" "$libexec/"
chmod 0755 "$libexec/hook-tests" "$libexec/relocation-tests"

cat > "$stage/var/jb/usr/bin/burrow-tests" <<'SCRIPT'
#!/var/jb/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Runs Burrow's tests on this device.
dir=/var/jb/usr/libexec/burrow-tests
failed=0
uname -m
"$dir/relocation-tests" || failed=$((failed + 1))
for mode in direct island adrp abs adrp-far abs-far; do
    "$dir/hook-tests" "$mode" || failed=$((failed + 1))
done
if [ "$failed" -eq 0 ]; then
    echo "Burrow tests: all passed"
else
    echo "Burrow tests: $failed of 7 programs failed"
    exit 1
fi
SCRIPT
chmod 0755 "$stage/var/jb/usr/bin/burrow-tests"

cat > "$stage/DEBIAN/control" <<CONTROL
Package: $package
Name: Burrow Tests
Version: $version
Architecture: $architecture
Section: Development
Maintainer: Nexus-jb
Author: Nexus-jb
Homepage: https://github.com/Nexus-jb/burrow
Description: Test programs for the Burrow hooking engine
 Development builds only. Run burrow-tests in a terminal to check that
 Burrow can hook functions on this device.
CONTROL

mkdir -p "$out"
deb="$out/${package}_${version}_${architecture}.deb"
dpkg-deb -Zxz --root-owner-group --build "$stage" "$deb" >/dev/null
echo "$deb"
