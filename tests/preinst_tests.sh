#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Tests scripts/preinst.sh, the package's check for an A12 chip or newer,
# with stand-ins for sysctl and uname.

set -u

script=$(cd "$(dirname "$0")/.." && pwd)/scripts/preinst.sh
stubs=$(mktemp -d)
trap 'rm -rf "$stubs"' EXIT

# sysctl prints TEST_CPUTYPE and TEST_CPUSUBTYPE, and fails without them.
cat > "$stubs/sysctl" <<'STUB'
#!/bin/sh
case "$2" in
    hw.cputype) value=${TEST_CPUTYPE-} ;;
    hw.cpusubtype) value=${TEST_CPUSUBTYPE-} ;;
    *) value= ;;
esac
[ -n "$value" ] || exit 1
echo "$value"
STUB
# uname -m prints TEST_MODEL, and fails without it.
cat > "$stubs/uname" <<'STUB'
#!/bin/sh
[ -n "${TEST_MODEL-}" ] || exit 1
echo "$TEST_MODEL"
STUB
chmod 0755 "$stubs/sysctl" "$stubs/uname"

checks=0
failures=0

# expect STATUS ACTION CPUTYPE CPUSUBTYPE MODEL
expect() {
    checks=$((checks + 1))
    output=$(PATH="$stubs:$PATH" TEST_CPUTYPE=$3 TEST_CPUSUBTYPE=$4 TEST_MODEL=$5 sh "$script" "$2" 2>&1)
    status=$?
    if [ "$status" -ne "$1" ]; then
        failures=$((failures + 1))
        echo "[preinst] $2 with cputype '$3', subtype '$4', model '$5': exit $status, expected $1" >&2
        return
    fi
    if [ "$1" -ne 0 ]; then
        checks=$((checks + 1))
        case "$output" in
            *"A12 chip or newer"*"(${5:-unknown model})"*) ;;
            *)
                failures=$((failures + 1))
                echo "[preinst] unclear message: $output" >&2
                ;;
        esac
    fi
}

# sysctl decides.
expect 0 install 16777228 2 iPhone15,3
expect 0 install 16777228 2147483650 iPhone15,3
expect 1 install 16777228 0 iPhone10,6
expect 1 install 16777228 1 iPhone10,6
expect 1 upgrade 16777228 1 ''
# Even an arm64e model is refused when the CPU is not arm64e.
expect 1 install 16777228 1 iPhone15,3
# Without sysctl, the model decides.
expect 0 install '' '' iPhone15,3
expect 0 install '' '' iPhone11,8
expect 0 install '' '' iPad8,1
expect 0 install '' '' iPad11,6
expect 1 install '' '' iPhone10,6
expect 1 install '' '' iPhone9,1
expect 1 install '' '' iPad7,11
expect 1 install '' '' iPad6,3
expect 1 install '' '' iPod9,1
# Neither can tell: let it through.
expect 0 install '' '' ''
expect 0 install 7 2 Mac14,2
expect 0 install 16777228 x iPhone15,3
# Only install and upgrade are checked.
expect 0 remove 16777228 1 iPhone10,6
expect 0 abort-upgrade 16777228 1 iPhone10,6

if [ "$failures" -ne 0 ]; then
    echo "[preinst] $failures of $checks checks failed" >&2
    exit 1
fi
echo "[preinst] $checks checks passed"
