#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Packages Burrow for a rootless jailbreak:
#
#   scripts/package-burrow.sh <build-dir> <version> <out-dir>
#
# <build-dir> holds the universal (arm64 and arm64e) BurrowLoader.dylib,
# CydiaSubstrate, burrowd and burrowctl. This package installs Burrow
# beside the jailbreak's own tweak loader and changes nothing the system
# uses: burrowd keeps the crash log, and burrowctl shows it.

set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <build-dir> <version> <out-dir>" >&2
    exit 2
fi
build=$1
version=$2
out=$3
package=com.nexusjb.burrow
architecture=iphoneos-arm64

if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}([~+][0-9A-Za-z.]+)?$'; then
    echo "invalid version: $version" >&2
    exit 1
fi
for file in BurrowLoader.dylib CydiaSubstrate burrowd burrowctl; do
    if [ ! -f "$build/$file" ]; then
        echo "missing: $build/$file" >&2
        exit 1
    fi
done

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
chmod 0755 "$stage"
root="$stage/var/jb"
mkdir -p "$root/usr/lib/burrow/CydiaSubstrate.framework" "$root/usr/libexec/burrow" "$root/usr/bin" \
    "$root/Library/LaunchDaemons" "$root/usr/share/doc/burrow" "$stage/DEBIAN"
install -m 0755 "$build/BurrowLoader.dylib" "$root/usr/lib/burrow/BurrowLoader.dylib"
install -m 0755 "$build/CydiaSubstrate" "$root/usr/lib/burrow/CydiaSubstrate.framework/CydiaSubstrate"
install -m 0755 "$build/burrowd" "$root/usr/libexec/burrow/burrowd"
install -m 0755 "$build/burrowctl" "$root/usr/bin/burrowctl"
install -m 0644 LICENSE "$root/usr/share/doc/burrow/LICENSE"

cat > "$root/Library/LaunchDaemons/com.nexusjb.burrowd.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.nexusjb.burrowd</string>
	<key>ProgramArguments</key>
	<array>
		<string>/var/jb/usr/libexec/burrow/burrowd</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>UserName</key>
	<string>root</string>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
PLIST
chmod 0644 "$root/Library/LaunchDaemons/com.nexusjb.burrowd.plist"

cat > "$stage/DEBIAN/control" <<CONTROL
Package: $package
Name: Burrow
Version: $version
Architecture: $architecture
Section: System
Depends: firmware (>= 15.0)
Maintainer: Nexus-jb
Author: Nexus-jb
Homepage: https://github.com/Nexus-jb/burrow
Description: Tweak injection platform (development build)
 This development build keeps a crash log of every crash with tweaks
 loaded and names the tweak to blame. The jailbreak's own tweak loader
 keeps loading tweaks until "burrowctl loader burrow" switches to Burrow's,
 and "burrowctl loader ellekit" switches back. Run burrowctl status.
CONTROL

cat > "$stage/DEBIAN/postinst" <<'SCRIPT'
#!/var/jb/bin/sh
# SPDX-License-Identifier: Apache-2.0
mkdir -p /var/jb/var/lib/burrow/crashes /var/jb/etc/burrow
if [ "$1" = configure ]; then
    launchctl unload /var/jb/Library/LaunchDaemons/com.nexusjb.burrowd.plist >/dev/null 2>&1 || true
    launchctl load -w /var/jb/Library/LaunchDaemons/com.nexusjb.burrowd.plist || true
fi
exit 0
SCRIPT
cat > "$stage/DEBIAN/prerm" <<'SCRIPT'
#!/var/jb/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Removing Burrow gives the hooking engine and the tweak loader back to
# ElleKit first.
if [ "$1" = remove ] || [ "$1" = deconfigure ]; then
    /var/jb/usr/bin/burrowctl engine ellekit >/dev/null 2>&1 || true
    /var/jb/usr/bin/burrowctl loader ellekit >/dev/null 2>&1 || true
fi
launchctl unload /var/jb/Library/LaunchDaemons/com.nexusjb.burrowd.plist >/dev/null 2>&1 || true
exit 0
SCRIPT
cat > "$stage/DEBIAN/postrm" <<'SCRIPT'
#!/var/jb/bin/sh
# SPDX-License-Identifier: Apache-2.0
# In case burrowctl could not run: no link to a removed loader or engine is
# left, and ElleKit's files are back.
undo() {
    if [ -L "$1" ] && [ "$(readlink "$1")" = "$3" ]; then
        rm -f "$1"
    fi
    dpkg-divert --package com.nexusjb.burrow --rename --divert "$2" --remove "$1" >/dev/null 2>&1 || true
}
if [ "$1" = remove ] || [ "$1" = purge ]; then
    engine=/var/jb/usr/lib/burrow/CydiaSubstrate.framework/CydiaSubstrate
    undo /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate \
        /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate.ellekit "$engine"
    for library in libsubstrate libhooker libblackjack; do
        undo "/var/jb/usr/lib/$library.dylib" "/var/jb/usr/lib/$library.ellekit.dylib" "$engine"
    done
    undo /var/jb/usr/lib/TweakLoader.dylib /var/jb/usr/lib/TweakLoader.ellekit.dylib \
        /var/jb/usr/lib/burrow/BurrowLoader.dylib
fi
if [ "$1" = purge ]; then
    rm -rf /var/jb/var/lib/burrow
fi
exit 0
SCRIPT
chmod 0755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm" "$stage/DEBIAN/postrm"

mkdir -p "$out"
deb="$out/${package}_${version}_${architecture}.deb"
dpkg-deb -Zxz --root-owner-group --build "$stage" "$deb" >/dev/null
echo "$deb"
