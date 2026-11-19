#!/var/jb/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# The Burrow package's preinst: Burrow supports the Apple A12 chip and newer,
# the arm64e chips with pointer authentication, and refuses to install on
# older ones.
#
# The CPU comes from sysctl: CPU type 16777228 is arm64, and subtype 2 is
# arm64e. When sysctl cannot tell, the model from uname -m decides: iPhone10
# (A11) and older, iPad7 (A10X) and older, and every iPod are older chips. A
# device neither can place is let through.

PATH="$PATH:/var/jb/usr/sbin:/var/jb/usr/bin:/var/jb/sbin:/var/jb/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Prints yes, no or unknown.
arm64e_from_sysctl() {
    type=$(sysctl -n hw.cputype 2>/dev/null) || type=
    subtype=$(sysctl -n hw.cpusubtype 2>/dev/null) || subtype=
    case "$type:$subtype" in
        16777228:*[!0-9]* | 16777228:) echo unknown ;;
        16777228:*)
            # The low byte is the subtype; higher bits are flags.
            if [ $((subtype & 255)) -eq 2 ]; then echo yes; else echo no; fi
            ;;
        *) echo unknown ;;
    esac
}

arm64e_from_model() {
    case "$1" in
        iPhone[0-9],* | iPhone10,*) echo no ;;
        iPad[0-7],*) echo no ;;
        iPod*) echo no ;;
        *) echo unknown ;;
    esac
}

case "$1" in
    install | upgrade) ;;
    *) exit 0 ;;
esac

model=$(uname -m 2>/dev/null) || model=
answer=$(arm64e_from_sysctl)
if [ "$answer" = unknown ]; then
    answer=$(arm64e_from_model "$model")
fi
if [ "$answer" = no ]; then
    echo "Burrow needs an Apple A12 chip or newer: iPhone XS, iPhone XR or a later device." >&2
    echo "This device (${model:-unknown model}) has an older chip, without the pointer authentication Burrow is built for. Nothing was installed." >&2
    exit 1
fi
exit 0
