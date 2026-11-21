# SPDX-License-Identifier: Apache-2.0
#
# make                 build the static library
# make test            run every test (arm64 Linux or macOS)
# make test-relocation run the relocation unit tests (any host)
# make test-jbroot     run the tests for finding the jailbreak root (any host)
# make test-loader     run the loader tests (macOS)
# make test-safemode   run the Safe Mode tests (macOS; they crash a test program)
#
# Cross-testing from another Linux machine:
#   make test CC=aarch64-linux-gnu-gcc RUN="qemu-aarch64 -L /usr/aarch64-linux-gnu"
#
# Testing on a jailbroken device (needs Xcode, ldid and dpkg):
#   make ios-tests-package PACKAGE_VERSION=0.0.0~dev.1
# then install the package from build/packages and run "burrow-tests".
#
# The Burrow packages, for rootless jailbreaks and for RootHide:
#   make burrow-package PACKAGE_VERSION=0.0.0~dev.1

CC ?= cc
AR ?= ar
CFLAGS ?= -O2 -g
BUILD ?= build
RUN ?=
SANITIZE ?= 0

WARNINGS := -Wall -Wextra -Werror -Wshadow -Wstrict-prototypes -Wmissing-prototypes
COMMON := -std=gnu11 $(WARNINGS) -fPIC -Iinclude -Isrc

ifeq ($(SANITIZE),1)
COMMON += -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
LDFLAGS += -fsanitize=address,undefined
endif

PORTABLE := src/arm64.c src/relocate.c src/memory_common.c
OBJC := src/objc.c src/objc_stubs.S
COMPAT := src/compat.c src/symbols.c
LOADER_TEST_SOURCES := src/loader.c src/jbroot.c daemon/state.m tests/loader/tweak.c tests/loader/target.c tests/loader_tests.c \
	$(wildcard tests/loader/TweakInject/*.plist) scripts/build-loader-tests.sh tests/ios.entitlements \
	$(wildcard safemode/*.h safemode/*.m daemon/*.h) daemon/switch.m daemon/inspect.m tests/safemode_tests.m \
	tests/safemode/crash_tweak.c \
	$(wildcard tests/safemode/CrashInject/*.plist tests/safemode/fixtures/*.ips) \
	tests/safemode/dpkg/status
DARWIN_LIBRARY := $(PORTABLE) src/hook.c src/memory_darwin.c $(OBJC)
SERVICE := safemode/crash_report.m safemode/crash_analysis.m safemode/safe_mode.m safemode/crash_log.m \
	safemode/crash_json.m safemode/packages.m safemode/service.m daemon/state.m daemon/switch.m daemon/inspect.m \
	src/jbroot.c
SERVICE_HEADERS := $(wildcard safemode/*.h daemon/*.h)

ifeq ($(shell uname -s),Darwin)
LIBRARY := $(DARWIN_LIBRARY) $(COMPAT)
LDLIBS += -lobjc
OBJC_TESTS := $(BUILD)/objc-tests
LOADER_TESTS := test-loader test-safemode
DL :=
else
LIBRARY := $(PORTABLE) src/hook.c src/memory_linux.c
LDLIBS += -pthread
DL := -ldl
OBJC_TESTS :=
LOADER_TESTS :=
endif

IOS_CC ?= xcrun --sdk iphoneos clang
IOS_ARCHS := arm64 arm64e
IOS_BUILD := $(BUILD)/ios
IOS_PROGRAMS := hook-tests relocation-tests objc-tests substrate-tests \
	frameworks/CydiaSubstrate.framework/CydiaSubstrate loader/loader-tests BurrowLoader.dylib
LDID ?= ldid
GNUMAKE ?= gmake
PACKAGE_VERSION ?= 0.0.0~dev
HEADERS := $(wildcard include/burrow/*.h src/*.h)
MODES := direct island adrp abs adrp-far abs-far

.PHONY: all test test-relocation test-jbroot test-preinst test-loader test-safemode ios-tests ios-tests-package burrow-package clean

all: $(BUILD)/libburrow.a

$(BUILD)/lib:
	mkdir -p $@

$(BUILD)/lib/%.o: src/%.c $(HEADERS) | $(BUILD)/lib
	$(CC) $(COMMON) -fvisibility=hidden $(CFLAGS) -c $< -o $@

$(BUILD)/lib/%.o: src/%.S $(HEADERS) | $(BUILD)/lib
	$(CC) $(COMMON) $(CFLAGS) -c $< -o $@

$(BUILD)/libburrow.a: $(patsubst src/%,$(BUILD)/lib/%.o,$(basename $(LIBRARY)))
	$(AR) rcs $@ $^

$(BUILD)/relocation-tests: tests/relocation_tests.c $(PORTABLE) $(HEADERS) | $(BUILD)/lib
	$(CC) $(COMMON) $(CFLAGS) tests/relocation_tests.c $(PORTABLE) -o $@ $(LDFLAGS)

$(BUILD)/hook-tests: tests/hook_tests.c tests/targets.S $(LIBRARY) $(HEADERS) | $(BUILD)/lib
	$(CC) $(COMMON) -DBURROW_TESTING $(CFLAGS) tests/hook_tests.c tests/targets.S $(LIBRARY) -o $@ $(LDFLAGS) $(LDLIBS)

test-relocation: $(BUILD)/relocation-tests
	$(RUN) $(BUILD)/relocation-tests

# Built as for a rootless jailbreak and as for RootHide.
$(BUILD)/jbroot-tests: tests/jbroot_tests.c src/jbroot.c src/jbroot.h | $(BUILD)/lib
	$(CC) $(COMMON) $(CFLAGS) tests/jbroot_tests.c src/jbroot.c -o $@ $(LDFLAGS) $(DL)

$(BUILD)/jbroot-tests-roothide: tests/jbroot_tests.c src/jbroot.c src/jbroot.h | $(BUILD)/lib
	$(CC) $(COMMON) -DBURROW_ROOTHIDE $(CFLAGS) tests/jbroot_tests.c src/jbroot.c -o $@ $(LDFLAGS) $(DL)

test-jbroot: $(BUILD)/jbroot-tests $(BUILD)/jbroot-tests-roothide
	$(RUN) $(BUILD)/jbroot-tests
	$(RUN) $(BUILD)/jbroot-tests-roothide

$(BUILD)/objc-tests: tests/objc_tests.c $(LIBRARY) $(HEADERS) | $(BUILD)/lib
	$(CC) $(COMMON) $(CFLAGS) tests/objc_tests.c $(LIBRARY) -o $@ $(LDFLAGS) $(LDLIBS)

# The loader tests build their own set of programs (see the script).
$(BUILD)/loader/loader-tests: $(LOADER_TEST_SOURCES) $(HEADERS)
	scripts/build-loader-tests.sh $(BUILD)/loader macos $(CC)

test-loader: $(BUILD)/loader/loader-tests
	$(RUN) $(BUILD)/loader/loader-tests $(BUILD)/loader

test-safemode: $(BUILD)/loader/loader-tests
	$(RUN) $(BUILD)/loader/safemode-tests $(BUILD)/loader

# The package's check for an A12 chip or newer.
test-preinst:
	sh tests/preinst_tests.sh

test: test-relocation test-jbroot test-preinst $(BUILD)/hook-tests $(OBJC_TESTS) $(LOADER_TESTS)
	@for mode in $(MODES); do $(RUN) $(BUILD)/hook-tests $$mode || exit 1; done
	@for program in $(OBJC_TESTS); do $(RUN) $$program || exit 1; done

# One set of test programs per architecture: build/ios/arm64, build/ios/arm64e.
$(IOS_BUILD)/%/hook-tests: tests/hook_tests.c tests/targets.S $(DARWIN_LIBRARY) $(HEADERS) tests/ios.entitlements
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) -DBURROW_TESTING $(CFLAGS) tests/hook_tests.c tests/targets.S $(DARWIN_LIBRARY) -o $@ -lobjc
	$(LDID) -Stests/ios.entitlements $@

$(IOS_BUILD)/%/objc-tests: tests/objc_tests.c $(DARWIN_LIBRARY) $(HEADERS) tests/ios.entitlements
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) $(CFLAGS) tests/objc_tests.c $(DARWIN_LIBRARY) -o $@ -lobjc
	$(LDID) -Stests/ios.entitlements $@

$(IOS_BUILD)/%/relocation-tests: tests/relocation_tests.c $(PORTABLE) $(HEADERS) tests/ios.entitlements
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) $(CFLAGS) tests/relocation_tests.c $(PORTABLE) -o $@
	$(LDID) -Stests/ios.entitlements $@

# Burrow built as Cydia Substrate: the library that tweaks load.
$(IOS_BUILD)/%/frameworks/CydiaSubstrate.framework/CydiaSubstrate: $(DARWIN_LIBRARY) $(COMPAT) $(HEADERS)
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) -fvisibility=hidden $(CFLAGS) -dynamiclib \
		-install_name @rpath/CydiaSubstrate.framework/CydiaSubstrate $(DARWIN_LIBRARY) $(COMPAT) -o $@ -lobjc
	$(LDID) -S $@

# Does not link Burrow: it reaches Burrow through the tweak it loads.
$(IOS_BUILD)/%/substrate-tests: tests/substrate_tests.c $(HEADERS) tests/ios.entitlements
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) $(CFLAGS) tests/substrate_tests.c -o $@ -lobjc
	$(LDID) -Stests/ios.entitlements $@

# The tweak loader. It finds the jailbreak root, and the tweak directory in
# it, when it starts (src/jbroot.h).
$(IOS_BUILD)/%/BurrowLoader.dylib: src/loader.c src/jbroot.c $(HEADERS)
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) -fvisibility=hidden $(CFLAGS) -dynamiclib \
		-install_name @rpath/BurrowLoader.dylib src/loader.c src/jbroot.c -o $@ -framework CoreFoundation -lobjc
	$(LDID) -S $@

$(IOS_BUILD)/%/loader/loader-tests: $(LOADER_TEST_SOURCES) $(HEADERS)
	LDID="$(LDID)" scripts/build-loader-tests.sh $(IOS_BUILD)/$*/loader ios $(IOS_CC) -arch $* -mios-version-min=15.0

# burrowd and burrowctl: Objective-C, never loaded into other processes.
$(IOS_BUILD)/%/burrowd: daemon/burrowd.m $(SERVICE) $(SERVICE_HEADERS)
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) -fobjc-arc -Isafemode -Idaemon $(CFLAGS) \
		daemon/burrowd.m $(SERVICE) -o $@ -framework Foundation
	$(LDID) -S $@

$(IOS_BUILD)/%/burrowctl: daemon/burrowctl.m $(SERVICE) $(SERVICE_HEADERS)
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) -fobjc-arc -Isafemode -Idaemon $(CFLAGS) \
		daemon/burrowctl.m $(SERVICE) -o $@ -framework Foundation
	$(LDID) -S $@

# The crash probe for checking burrowd on a device (see the probe's source).
$(IOS_BUILD)/%/burrow-crash-probe: tests/safemode/probe/probe.c tests/ios.entitlements
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) $(CFLAGS) tests/safemode/probe/probe.c -o $@
	$(LDID) -Stests/ios.entitlements $@

$(IOS_BUILD)/%/BurrowCrashProbe.dylib: tests/safemode/crash_tweak.c
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) $(CFLAGS) -dynamiclib -DBURROW_CRASH=1 \
		-install_name @rpath/BurrowCrashProbe.dylib tests/safemode/crash_tweak.c -o $@ -lobjc
	$(LDID) -S $@

# The same three for RootHide: they find the hidden root from where they are
# installed (src/jbroot.h).
IOS_ROOTHIDE := $(BUILD)/ios-roothide

$(IOS_ROOTHIDE)/%/BurrowLoader.dylib: src/loader.c src/jbroot.c $(HEADERS)
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) -DBURROW_ROOTHIDE -fvisibility=hidden $(CFLAGS) -dynamiclib \
		-install_name @rpath/BurrowLoader.dylib src/loader.c src/jbroot.c -o $@ -framework CoreFoundation -lobjc
	$(LDID) -S $@

$(IOS_ROOTHIDE)/%/burrowd: daemon/burrowd.m $(SERVICE) $(SERVICE_HEADERS)
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) -DBURROW_ROOTHIDE -fobjc-arc -Isafemode -Idaemon $(CFLAGS) \
		daemon/burrowd.m $(SERVICE) -o $@ -framework Foundation
	$(LDID) -S $@

$(IOS_ROOTHIDE)/%/burrowctl: daemon/burrowctl.m $(SERVICE) $(SERVICE_HEADERS)
	mkdir -p $(@D)
	$(IOS_CC) -arch $* -mios-version-min=15.0 $(COMMON) -DBURROW_ROOTHIDE -fobjc-arc -Isafemode -Idaemon $(CFLAGS) \
		daemon/burrowctl.m $(SERVICE) -o $@ -framework Foundation
	$(LDID) -S $@

# Universal binaries for the packages: every process, arm64 or arm64e, can
# load the libraries.
IOS_UNIVERSAL := $(BUILD)/ios-universal
IOS_UNIVERSAL_ROOTHIDE := $(BUILD)/ios-universal-roothide
UNIVERSAL := BurrowLoader.dylib burrowd burrowctl
PROBE := burrow-crash-probe BurrowCrashProbe.dylib

$(IOS_UNIVERSAL)/%: $(IOS_BUILD)/arm64/% $(IOS_BUILD)/arm64e/%
	mkdir -p $(@D)
	lipo -create $^ -output $@

$(IOS_UNIVERSAL)/CydiaSubstrate: $(foreach arch,$(IOS_ARCHS),$(IOS_BUILD)/$(arch)/frameworks/CydiaSubstrate.framework/CydiaSubstrate)
	mkdir -p $(@D)
	lipo -create $^ -output $@

$(IOS_UNIVERSAL_ROOTHIDE)/%: $(IOS_ROOTHIDE)/arm64/% $(IOS_ROOTHIDE)/arm64e/%
	mkdir -p $(@D)
	lipo -create $^ -output $@

# The hooking engine names no jailbreak path: both packages carry the same.
$(IOS_UNIVERSAL_ROOTHIDE)/CydiaSubstrate: $(IOS_UNIVERSAL)/CydiaSubstrate
	mkdir -p $(@D)
	cp $< $@

# Both packages: iphoneos-arm64 for rootless jailbreaks and iphoneos-arm64e
# for RootHide.
burrow-package: $(addprefix $(IOS_UNIVERSAL)/,$(UNIVERSAL) CydiaSubstrate) \
		$(addprefix $(IOS_UNIVERSAL_ROOTHIDE)/,$(UNIVERSAL) CydiaSubstrate)
	scripts/package-burrow.sh $(IOS_UNIVERSAL) $(PACKAGE_VERSION) $(BUILD)/packages rootless
	scripts/package-burrow.sh $(IOS_UNIVERSAL_ROOTHIDE) $(PACKAGE_VERSION) $(BUILD)/packages roothide

# The sample tweak, built with Theos (needs THEOS and GNU Make 4).
$(IOS_BUILD)/BurrowSampleTweak.dylib: tests/tweak/Tweak.x tests/tweak/Makefile
	mkdir -p $(@D)
	$(GNUMAKE) -C tests/tweak FINALPACKAGE=1
	cp tests/tweak/.theos/obj/BurrowSampleTweak.dylib $@

ios-tests: $(foreach arch,$(IOS_ARCHS),$(addprefix $(IOS_BUILD)/$(arch)/,$(IOS_PROGRAMS))) \
	$(IOS_BUILD)/BurrowSampleTweak.dylib $(addprefix $(IOS_UNIVERSAL)/,$(PROBE))

# The same test programs in both packages: rootless and RootHide.
ios-tests-package: ios-tests
	scripts/package-tests.sh $(IOS_BUILD) $(PACKAGE_VERSION) $(BUILD)/packages $(IOS_UNIVERSAL) rootless
	scripts/package-tests.sh $(IOS_BUILD) $(PACKAGE_VERSION) $(BUILD)/packages $(IOS_UNIVERSAL) roothide

clean:
	rm -rf $(BUILD)
