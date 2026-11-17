// SPDX-License-Identifier: Apache-2.0
//
// End-to-end tests of function hooking, run on arm64 Linux and macOS. Each
// mode runs in its own process, so every mode starts from unpatched code.
//
//   direct    one-word patches that branch straight to the replacement
//   island    one-word patches that branch through an island
//   adrp      patches of at least three words (ADRP, ADD, BR)
//   abs       four-word patches (LDR literal, BR, address)
//   adrp-far  as adrp, with trampolines more than 4 GiB from their targets
//   abs-far   as abs, with trampolines more than 4 GiB from their targets

#include <burrow/burrow.h>

#include "arm64.h"
#include "internal.h"
#include "memory.h"

#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define UNDER_ASAN 1
#endif
#endif
#if defined(__SANITIZE_ADDRESS__)
#define UNDER_ASAN 1
#endif

typedef uint64_t (*fn)(uint64_t);

struct mode {
    const char *name;
    struct burrow_test_options options;
    size_t words;  // Smallest patch the mode allows.
};

static const struct mode modes[] = {
    { "direct", { false, 0, false }, 1 },
    { "island", { true, 0, false }, 1 },
    { "adrp", { false, 3, false }, 3 },
    { "abs", { false, 4, false }, 4 },
    { "adrp-far", { false, 3, true }, 3 },
    { "abs-far", { false, 4, true }, 4 },
};

static const struct mode *mode;
static const char *current;
static int failures;
static int checks;

#define CHECK(condition)                                                                          \
    do {                                                                                          \
        checks++;                                                                                 \
        if (!(condition)) {                                                                       \
            failures++;                                                                           \
            fprintf(stderr, "[%s] %s: line %d: %s\n", mode->name, current, __LINE__, #condition); \
        }                                                                                         \
    } while (0)

static const uint64_t inputs[] = { 0, 3, 4, 8, 9, 12, 100 };
#define INPUT_COUNT (sizeof inputs / sizeof inputs[0])

static uintptr_t address_of(fn function) {
    return (uintptr_t)function;
}

static uint64_t distance(uintptr_t a, uintptr_t b) {
    return a > b ? a - b : b - a;
}

// Targets whose first instructions any patch size can move.
#define MOVABLE(X) \
    X(t_plain)     \
    X(t_adr)       \
    X(t_adrp)      \
    X(t_ldr_x)     \
    X(t_ldr_w)     \
    X(t_ldrsw)     \
    X(t_ldr_d)     \
    X(t_ldr_q)     \
    X(t_prfm)      \
    X(t_bl)        \
    X(t_bcond)     \
    X(t_cbz)       \
    X(t_cbnz)      \
    X(t_tbz)       \
    X(t_tbnz)      \
    X(t_loop)      \
    X(t_x17)

// Targets where only a one-word patch is safe.
#define ONE_WORD_ONLY(X) \
    X(t_x16_x17)         \
    X(t_b_entry)         \
    X(t_short)           \
    X(t_inbound)

#define DECLARE(name)                                     \
    uint64_t name(uint64_t);                              \
    static fn name##_original;                            \
    static uint64_t name##_replacement(uint64_t x) {      \
        return name##_original(x) * 2 + 1;                \
    }
MOVABLE(DECLARE)
ONE_WORD_ONLY(DECLARE)

uint64_t t_after_short(uint64_t);
uint64_t t_chain(uint64_t);
uint64_t t_foreign(uint64_t);
uint64_t t_duplicate(uint64_t);
uint64_t t_batch_a(uint64_t);
uint64_t t_batch_b(uint64_t);
uint64_t t_batch_partial(uint64_t);

// Checks the shape of an installed patch against the mode.
static void check_patch(fn target, fn replacement, fn original) {
    const uint32_t *code = (const uint32_t *)address_of(target);
    const a64_insn first = a64_decode(code[0]);
    if (mode->words == 1) {
        CHECK(first.kind == A64_B);
        uintptr_t to = address_of(target) + (uintptr_t)first.offset;
        if (mode->options.no_direct_branch) {
            CHECK(to != address_of(replacement));
        } else {
            CHECK(to == address_of(replacement));
        }
    } else if (first.kind == A64_ADRP) {
        CHECK(mode->words == 3);
        CHECK(code[1] == a64_add_imm(first.reg, first.reg, (unsigned)(address_of(replacement) & 0xFFF)));
        CHECK(code[2] == a64_br(first.reg));
    } else {
        CHECK(a64_is_absolute_jump(code, 4));
        CHECK((code[2] | (uint64_t)code[3] << 32) == address_of(replacement));
    }
    if (mode->options.far_trampolines) {
        CHECK(distance(address_of(original), address_of(target)) > ((uint64_t)4 << 30));
    }
}

static void test_target(const char *name, fn target, fn replacement, fn *original, bool movable) {
    current = name;
    uint64_t before[INPUT_COUNT];
    for (size_t i = 0; i < INPUT_COUNT; i++) {
        before[i] = target(inputs[i]);
    }
    uint32_t code_before[4];
    memcpy(code_before, (const void *)address_of(target), sizeof code_before);

    burrow_status status = burrow_hook_function((void *)address_of(target), (void *)address_of(replacement),
                                                (void **)original);

    if (!movable && mode->words > 1) {
        CHECK(status == BURROW_ERR_UNSUPPORTED);
        CHECK(memcmp(code_before, (const void *)address_of(target), sizeof code_before) == 0);
        CHECK(*original == NULL);
        for (size_t i = 0; i < INPUT_COUNT; i++) {
            CHECK(target(inputs[i]) == before[i]);
        }
        return;
    }

    CHECK(status == BURROW_OK);
    if (status != BURROW_OK || !*original) {
        fprintf(stderr, "[%s] %s: %s\n", mode->name, name, burrow_status_string(status));
        return;
    }
    for (size_t i = 0; i < INPUT_COUNT; i++) {
        CHECK(target(inputs[i]) == before[i] * 2 + 1);
        CHECK((*original)(inputs[i]) == before[i]);
    }
    check_patch(target, replacement, *original);
}

// The neighbor of a one-instruction function must survive its hook.
static void test_short_neighbor(void) {
    current = "t_after_short";
    for (size_t i = 0; i < INPUT_COUNT; i++) {
        CHECK(t_after_short(inputs[i]) == inputs[i] + 1);
    }
}

static fn chain_first_original;
static fn chain_second_original;

static uint64_t chain_first(uint64_t x) {
    return chain_first_original(x) + 10;
}

static uint64_t chain_second(uint64_t x) {
    return chain_second_original(x) * 3;
}

// Hooking a function twice: the newest hook runs first.
static void test_chain(void) {
    current = "chain";
    CHECK(burrow_hook_function((void *)address_of(t_chain), (void *)address_of(chain_first),
                               (void **)&chain_first_original) == BURROW_OK);
    CHECK(burrow_hook_function((void *)address_of(t_chain), (void *)address_of(chain_second),
                               (void **)&chain_second_original) == BURROW_OK);
    for (size_t i = 0; i < INPUT_COUNT; i++) {
        CHECK(t_chain(inputs[i]) == (inputs[i] + 1 + 10) * 3);
    }
}

static uint64_t foreign_replacement(uint64_t x) {
    return x + 1000;
}

static fn foreign_original;

static uint64_t over_foreign(uint64_t x) {
    return foreign_original(x) * 2;
}

// Hooking a function that another library already patched with the usual
// absolute jump.
static void test_foreign_patch(void) {
    current = "foreign";
    uintptr_t to = address_of(foreign_replacement);
    const uint32_t patch[4] = { a64_ldr_literal_x(17, 8), a64_br(17), (uint32_t)to, (uint32_t)((uint64_t)to >> 32) };
    CHECK(burrow_write_code(address_of(t_foreign), patch, 4));
    CHECK(t_foreign(5) == 1005);
    CHECK(burrow_hook_function((void *)address_of(t_foreign), (void *)address_of(over_foreign),
                               (void **)&foreign_original) == BURROW_OK);
    for (size_t i = 0; i < INPUT_COUNT; i++) {
        CHECK(t_foreign(inputs[i]) == (inputs[i] + 1000) * 2);
    }
}

static uint32_t data_words[8] = { 0xD503201Fu };

static uint64_t plus_one_thousand(uint64_t x) {
    return x + 1000;
}

static void test_arguments(void) {
    current = "arguments";
    void *original = NULL;
    void *replacement = (void *)address_of(plus_one_thousand);
    CHECK(burrow_hook_function(NULL, replacement, &original) == BURROW_ERR_INVALID_ARGUMENT);
    CHECK(burrow_hook_function((void *)address_of(t_batch_partial), NULL, &original) == BURROW_ERR_INVALID_ARGUMENT);
    CHECK(burrow_hook_function((void *)(address_of(t_batch_partial) + 2), replacement, &original) ==
          BURROW_ERR_INVALID_ARGUMENT);
    CHECK(burrow_hook_function(data_words, replacement, &original) == BURROW_ERR_NOT_EXECUTABLE);
    CHECK(original == NULL);
    CHECK(burrow_hook_functions(NULL, 0, NULL) == BURROW_OK);
    CHECK(burrow_hook_functions(NULL, 1, NULL) == BURROW_ERR_INVALID_ARGUMENT);
    for (int status = BURROW_OK; status <= BURROW_ERR_PROTECTION; status++) {
        CHECK(strcmp(burrow_status_string((burrow_status)status), "unknown status") != 0);
    }
}

// A batch is installed whole or not at all.
static void test_batches(void) {
    current = "batches";
    uint32_t before[4];
    void *original_a = NULL;
    void *original_b = NULL;
    void *replacement = (void *)address_of(plus_one_thousand);

    memcpy(before, (const void *)address_of(t_duplicate), sizeof before);
    burrow_function_hook duplicate[2] = {
        { (void *)address_of(t_duplicate), replacement, &original_a },
        { (void *)address_of(t_duplicate), replacement, &original_b },
    };
    size_t failed = 99;
    CHECK(burrow_hook_functions(duplicate, 2, &failed) == BURROW_ERR_INVALID_ARGUMENT);
    CHECK(failed == 1);
    CHECK(memcmp(before, (const void *)address_of(t_duplicate), sizeof before) == 0);
    CHECK(original_a == NULL && original_b == NULL);

    memcpy(before, (const void *)address_of(t_batch_partial), sizeof before);
    burrow_function_hook partial[2] = {
        { (void *)address_of(t_batch_partial), replacement, &original_a },
        { data_words, replacement, &original_b },
    };
    failed = 99;
    CHECK(burrow_hook_functions(partial, 2, &failed) == BURROW_ERR_NOT_EXECUTABLE);
    CHECK(failed == 1);
    CHECK(memcmp(before, (const void *)address_of(t_batch_partial), sizeof before) == 0);
    CHECK(original_a == NULL);
    CHECK(t_batch_partial(1) == 2);

    burrow_function_hook both[2] = {
        { (void *)address_of(t_batch_a), replacement, &original_a },
        { (void *)address_of(t_batch_b), replacement, &original_b },
    };
    CHECK(burrow_hook_functions(both, 2, NULL) == BURROW_OK);
    CHECK(t_batch_a(1) == 1001 && t_batch_b(2) == 1002);
    CHECK(original_a && ((fn)original_a)(1) == 2);
    CHECK(original_b && ((fn)original_b)(2) == 3);
}

static size_t append(char *line, size_t length, size_t capacity, const char *text) {
    while (*text && length + 1 < capacity) {
        line[length++] = *text++;
    }
    return length;
}

// Names the test that was running when a hook crashed the process. Only
// async-signal-safe calls are made here.
static void report_crash(int signal_number) {
    char line[256];
    char number[4] = { (char)('0' + signal_number / 10 % 10), (char)('0' + signal_number % 10), ')', 0 };
    size_t length = 0;
    length = append(line, length, sizeof line, "[");
    length = append(line, length, sizeof line, mode ? mode->name : "?");
    length = append(line, length, sizeof line, "] crashed in ");
    length = append(line, length, sizeof line, current ? current : "setup");
    length = append(line, length, sizeof line, " (signal ");
    length = append(line, length, sizeof line, number);
    length = append(line, length, sizeof line, "\n");
    (void)!write(STDERR_FILENO, line, length);
    _exit(128 + signal_number);
}

static void install_crash_reporter(void) {
#ifndef UNDER_ASAN
    static const int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = report_crash;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < sizeof signals / sizeof signals[0]; i++) {
        sigaction(signals[i], &action, NULL);
    }
#endif
}

int main(int argc, char **argv) {
    install_crash_reporter();
    if (argc != 2) {
        fprintf(stderr, "usage: %s MODE\n", argv[0]);
        return 2;
    }
    for (size_t i = 0; i < sizeof modes / sizeof modes[0]; i++) {
        if (strcmp(argv[1], modes[i].name) == 0) {
            mode = &modes[i];
        }
    }
    if (!mode) {
        fprintf(stderr, "unknown mode: %s\n", argv[1]);
        return 2;
    }
    burrow_set_test_options(&mode->options);

#define RUN_MOVABLE(name) test_target(#name, name, name##_replacement, &name##_original, true);
#define RUN_ONE_WORD(name) test_target(#name, name, name##_replacement, &name##_original, false);
    MOVABLE(RUN_MOVABLE)
    ONE_WORD_ONLY(RUN_ONE_WORD)
    test_short_neighbor();
    test_chain();
    test_foreign_patch();
    test_arguments();
    test_batches();

    if (failures) {
        fprintf(stderr, "[%s] %d of %d checks failed\n", mode->name, failures, checks);
        return 1;
    }
    printf("[%s] %d checks passed\n", mode->name, checks);
    return 0;
}
