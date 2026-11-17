# SPDX-License-Identifier: Apache-2.0
#
# make                 build the static library
# make test            run every test (arm64 Linux or macOS)
# make test-relocation run the relocation unit tests (any host)
#
# Cross-testing from another Linux machine:
#   make test CC=aarch64-linux-gnu-gcc RUN="qemu-aarch64 -L /usr/aarch64-linux-gnu"

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

ifeq ($(shell uname -s),Darwin)
PLATFORM := src/memory_darwin.c
else
PLATFORM := src/memory_linux.c
LDLIBS += -pthread
endif

PORTABLE := src/arm64.c src/relocate.c src/memory_common.c
LIBRARY := $(PORTABLE) src/hook.c $(PLATFORM)
HEADERS := $(wildcard include/burrow/*.h src/*.h)
MODES := direct island adrp abs adrp-far abs-far

.PHONY: all test test-relocation clean

all: $(BUILD)/libburrow.a

$(BUILD)/lib:
	mkdir -p $@

$(BUILD)/lib/%.o: src/%.c $(HEADERS) | $(BUILD)/lib
	$(CC) $(COMMON) -fvisibility=hidden $(CFLAGS) -c $< -o $@

$(BUILD)/libburrow.a: $(patsubst src/%.c,$(BUILD)/lib/%.o,$(LIBRARY))
	$(AR) rcs $@ $^

$(BUILD)/relocation-tests: tests/relocation_tests.c $(PORTABLE) $(HEADERS) | $(BUILD)/lib
	$(CC) $(COMMON) $(CFLAGS) tests/relocation_tests.c $(PORTABLE) -o $@ $(LDFLAGS)

$(BUILD)/hook-tests: tests/hook_tests.c tests/targets.S $(LIBRARY) $(HEADERS) | $(BUILD)/lib
	$(CC) $(COMMON) -DBURROW_TESTING $(CFLAGS) tests/hook_tests.c tests/targets.S $(LIBRARY) -o $@ $(LDFLAGS) $(LDLIBS)

test-relocation: $(BUILD)/relocation-tests
	$(RUN) $(BUILD)/relocation-tests

test: test-relocation $(BUILD)/hook-tests
	@for mode in $(MODES); do $(RUN) $(BUILD)/hook-tests $$mode || exit 1; done

clean:
	rm -rf $(BUILD)
