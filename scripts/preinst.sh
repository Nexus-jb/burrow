#!/var/jb/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# The Burrow package's preinst: Burrow supports the Apple A12 chip and newer,
# the arm64e chips with pointer authentication, and refuses to install on
# older ones.
#
# The model from uname -m decides, since Dopamine's bootstrap has no sysctl
# command. The older chips are a closed list: iPhone10 (A11) and older,
# iPad7 (A10X) and older, and every iPod. Any other device is let through.

PATH="$PATH:/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin"

case "$1" in
    install | upgrade) ;;
    *) exit 0 ;;
esac

model=$(uname -m 2>/dev/null) || model=
case "$model" in
    iPhone[0-9],* | iPhone10,* | iPad[0-7],* | iPod*)
        echo "Burrow needs an Apple A12 chip or newer: iPhone XS, iPhone XR or a later device." >&2
        echo "This device ($model) has an older chip, without the pointer authentication Burrow is built for. Nothing was installed." >&2
        exit 1
        ;;
esac
exit 0
