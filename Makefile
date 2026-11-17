# SPDX-License-Identifier: Apache-2.0
#
# make                 build the static library
# make test            run every test (arm64 Linux or macOS)
# make test-relocation run the relocation unit tests (any host)
#
# Cross-testing from another Linux machine:
#   make test CC=aarch64-linux-gnu-gcc RUN="qemu-aarch64 -L /usr/aarch64-linux-gnu"
#
# Testing on a jailbroken device (needs Xcode, ldid and dpkg):
#   make ios-tests-package PACKAGE_VERSION=0.0.0~dev.1
# then install the package from build/packages and run "burrow-tests".

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
DARWIN_LIBRARY := $(PORTABLE) src/hook.c src/memory_darwin.c $(OBJC)

ifeq ($(shell uname -s),Darwin)
LIBRARY := $(DARWIN_LIBRARY)
LDLIBS += -lobjc
OBJC_TESTS := $(BUILD)/objc-tests
else
LIBRARY := $(PORTABLE) src/hook.c src/memory_linux.c
LDLIBS += -pthread
OBJC_TESTS :=
endif

IOS_CC ?= xcrun --sdk iphoneos clang
IOS_ARCHS := arm64 arm64e
IOS_BUILD := $(BUILD)/ios
IOS_PROGRAMS := hook-tests relocation-tests objc-tests
LDID ?= ldid
PACKAGE_VERSION ?= 0.0.0~dev
HEADERS := $(wildcard include/burrow/*.h src/*.h)
MODES := direct island adrp abs adrp-far abs-far

.PHONY: all test test-relocation ios-tests ios-tests-package clean

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

$(BUILD)/objc-tests: tests/objc_tests.c $(LIBRARY) $(HEADERS) | $(BUILD)/lib
	$(CC) $(COMMON) $(CFLAGS) tests/objc_tests.c $(LIBRARY) -o $@ $(LDFLAGS) $(LDLIBS)

test: test-relocation $(BUILD)/hook-tests $(OBJC_TESTS)
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

ios-tests: $(foreach arch,$(IOS_ARCHS),$(addprefix $(IOS_BUILD)/$(arch)/,$(IOS_PROGRAMS)))

ios-tests-package: ios-tests
	scripts/package-tests.sh $(IOS_BUILD) $(PACKAGE_VERSION) $(BUILD)/packages

clean:
	rm -rf $(BUILD)
