#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Builds the loader and Safe Mode tests into one directory:
#
#   scripts/build-loader-tests.sh <out-dir> <macos|ios> <compiler> [flags...]
#
# The directory gets the test build of the loader, the test tweaks in
# TweakInject/ with their filters from tests/loader/TweakInject, the two
# test targets and loader-tests, which runs them. For Safe Mode and the
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
tweaks="000First AnyMode AppBundle BadPlist ClassFilter CurrentCFRange EitherKey EmptyFilter Executable FutureCF LowercaseBundle NewCF NoPlist OldCFRange OnlyCF OpenStep zManager"

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
    -install_name @rpath/BurrowLoaderTesting.dylib src/loader.c \
    -o "$out/BurrowLoaderTesting.dylib" -framework CoreFoundation -lobjc
sign "$out/BurrowLoaderTesting.dylib"

for tweak in $tweaks; do
    # shellcheck disable=SC2086
    "$@" $flags -dynamiclib -DBURROW_TWEAK_NAME="\"$tweak\"" -install_name "@rpath/$tweak.dylib" \
        -Wl,-U,_burrow_loader_record tests/loader/tweak.c -o "$out/TweakInject/$tweak.dylib"
    sign "$out/TweakInject/$tweak.dylib"
done
# Stands in for the old arm64e ABI shim, outside the tweak directory.
# shellcheck disable=SC2086
"$@" $flags -dynamiclib -DBURROW_TWEAK_NAME='"OldABI"' -install_name @rpath/OldABI.dylib \
    -Wl,-U,_burrow_loader_record tests/loader/tweak.c -o "$out/OldABI.dylib"
sign "$out/OldABI.dylib"
# Its filter matches every process, but the file is not a library.
printf 'not a library\n' > "$out/TweakInject/Broken.dylib"
cp tests/loader/TweakInject/*.plist "$out/TweakInject/"

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
"$@" $flags -fobjc-arc -Isafemode -Idaemon tests/safemode_tests.m safemode/*.m daemon/switch.m daemon/inspect.m \
    -o "$out/safemode-tests" -framework Foundation
sign "$out/safemode-tests" tests/ios.entitlements

# Compiling and linking in one step with -g leaves .dSYM folders beside
# each binary; the tests do not need them.
find "$out" -name '*.dSYM' -prune -exec rm -rf {} +
