#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Builds the loader and Safe Mode tests into one directory:
#
#   scripts/build-loader-tests.sh <out-dir> <macos|ios> <compiler> [flags...]
#
# The directory gets the test build of the loader, the test tweaks in
# TweakInject/ with their filters from tests/loader/TweakInject, the old
# arm64e ABI test tweak in LegacyInject/, the two test targets and
# loader-tests, which runs them. For Safe Mode and the
# crash log it gets crash-target, the test tweaks in CrashInject/ that crash
# it, the crash report fixtures, a dpkg database and safemode-tests:
#
#   loader-tests <out-dir>
#   safemode-tests <out-dir>
#
# For ios, every binary is signed with ldid (set LDID to override).

set -eu

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <out-dir> <macos|ios> <compiler> [flags...]" >&2
    exit 2
fi
out=$1
platform=$2
shift 2
case "$platform" in
    macos | ios) ;;
    *)
        echo "unknown platform: $platform" >&2
        exit 2
        ;;
esac

flags="-std=gnu11 -Wall -Wextra -Werror -Wshadow -Wstrict-prototypes -Wmissing-prototypes -O2 -g -Iinclude -Isrc"
ldid=${LDID:-ldid}
# NoPlist has no filter. BadPlist's filter cannot be read.
tweaks="000First AllFilters AllFiltersMiss AnyMode AppBundle BadPlist ClassFilter EmptyFilter Executable FutureCF NewCF NoPlist OldCFRange OpenStep zManager"

# sign <file> [entitlements]
sign() {
    if [ "$platform" = ios ]; then
        if [ "$#" -eq 2 ]; then
            "$ldid" "-S$2" "$1"
        else
            "$ldid" -S "$1"
        fi
    fi
}

rm -rf "$out"
mkdir -p "$out/TweakInject"

# shellcheck disable=SC2086 # $flags holds several flags.
"$@" $flags -DBURROW_LOADER_TESTING -fvisibility=hidden -dynamiclib \
    -install_name @rpath/BurrowLoaderTesting.dylib src/loader.c src/legacy_abi.c \
    -o "$out/BurrowLoaderTesting.dylib" -framework CoreFoundation -lobjc
sign "$out/BurrowLoaderTesting.dylib"

for tweak in $tweaks; do
    # shellcheck disable=SC2086
    "$@" $flags -dynamiclib -DBURROW_TWEAK_NAME="\"$tweak\"" -install_name "@rpath/$tweak.dylib" \
        -Wl,-U,_burrow_loader_record tests/loader/tweak.c -o "$out/TweakInject/$tweak.dylib"
    sign "$out/TweakInject/$tweak.dylib"
done
# Its filter matches every process, but the file is not a library.
printf 'not a library\n' > "$out/TweakInject/Broken.dylib"
cp tests/loader/TweakInject/*.plist "$out/TweakInject/"

# The old arm64e ABI check: LegacyABI has an Objective-C class, a slice for
# the test's own architecture (arm64 for iOS) and an arm64e slice marked as
# built for the old ABI: the pointer authentication ABI flag, the top bit of
# its CPU subtype, is cleared.
legacy="$out/LegacyInject"
mkdir -p "$legacy"
if [ "$platform" = ios ]; then
    own_arch=arm64
else
    own_arch=$(uname -m)
fi
for arch in "$own_arch" arm64e; do
    # shellcheck disable=SC2086
    "$@" $flags -arch "$arch" -dynamiclib -install_name @rpath/LegacyABI.dylib -Wl,-U,_burrow_loader_record \
        tests/loader/legacy_tweak.m -o "$legacy/$arch.dylib" -lobjc
    # The compiler command may name another architecture too.
    if [ "$(lipo -archs "$legacy/$arch.dylib" | wc -w)" -gt 1 ]; then
        lipo -thin "$arch" "$legacy/$arch.dylib" -output "$legacy/$arch.thin"
        mv "$legacy/$arch.thin" "$legacy/$arch.dylib"
    fi
done
# The CPU subtype is the little-endian word at offset 8; its top byte is 0x80
# for the current ABI.
if [ "$(od -An -tx1 -j11 -N1 "$legacy/arm64e.dylib" | tr -d ' \n')" != 80 ]; then
    echo "unexpected CPU subtype in the arm64e build of LegacyABI" >&2
    exit 1
fi
printf '\000' | dd of="$legacy/arm64e.dylib" bs=1 seek=11 count=1 conv=notrunc 2>/dev/null
lipo -create "$legacy/$own_arch.dylib" "$legacy/arm64e.dylib" -output "$legacy/LegacyABI.dylib"
rm "$legacy/$own_arch.dylib" "$legacy/arm64e.dylib"
sign "$legacy/LegacyABI.dylib"
cp tests/loader/LegacyInject/*.plist "$legacy/"

# shellcheck disable=SC2086
"$@" $flags tests/loader/target.c -o "$out/loader-target" -lobjc
sign "$out/loader-target" tests/ios.entitlements

if [ "$platform" = macos ]; then
    info="$out/LoaderTarget.app/Contents"
    executable_dir="$info/MacOS"
else
    info="$out/LoaderTarget.app"
    executable_dir="$info"
fi
mkdir -p "$executable_dir"
# Unlike loader-target, it uses Foundation, like every app.
# shellcheck disable=SC2086
"$@" $flags -DBURROW_LOADER_APP tests/loader/target.c -o "$executable_dir/LoaderTarget" -lobjc -framework Foundation
sign "$executable_dir/LoaderTarget" tests/ios.entitlements
cat > "$info/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>LoaderTarget</string>
	<key>CFBundleIdentifier</key>
	<string>com.nexusjb.burrow-tests.loader-target</string>
	<key>CFBundleName</key>
	<string>LoaderTarget</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
PLIST

# shellcheck disable=SC2086
"$@" $flags tests/loader_tests.c -o "$out/loader-tests"
sign "$out/loader-tests" tests/ios.entitlements

# Safe Mode: a target that uses Foundation, one tweak that loads quietly and
# two that crash it.
mkdir -p "$out/CrashInject"
# shellcheck disable=SC2086
"$@" $flags tests/loader/target.c -o "$out/crash-target" -lobjc -framework Foundation
sign "$out/crash-target" tests/ios.entitlements
# shellcheck disable=SC2086
"$@" $flags -dynamiclib -DBURROW_TWEAK_NAME='"Innocent"' -install_name @rpath/Innocent.dylib \
    -Wl,-U,_burrow_loader_record tests/loader/tweak.c -o "$out/CrashInject/Innocent.dylib"
sign "$out/CrashInject/Innocent.dylib"
crash=1
for tweak in SegvTweak ThrowTweak; do
    # shellcheck disable=SC2086
    "$@" $flags -dynamiclib -DBURROW_CRASH=$crash -install_name "@rpath/$tweak.dylib" \
        tests/safemode/crash_tweak.c -o "$out/CrashInject/$tweak.dylib" -lobjc
    sign "$out/CrashInject/$tweak.dylib"
    crash=$((crash + 1))
done
cp tests/safemode/CrashInject/*.plist "$out/CrashInject/"
mkdir -p "$out/safemode-fixtures"
cp tests/safemode/fixtures/*.ips "$out/safemode-fixtures/"
cp -R tests/safemode/dpkg "$out/safemode-dpkg"
# shellcheck disable=SC2086
"$@" $flags -fobjc-arc -Isafemode tests/safemode_tests.m safemode/*.m \
    -o "$out/safemode-tests" -framework Foundation
sign "$out/safemode-tests" tests/ios.entitlements

# Compiling and linking in one step with -g leaves .dSYM folders beside
# each binary; the tests do not need them.
find "$out" -name '*.dSYM' -prune -exec rm -rf {} +
