#include "BenchKitC.h"

uint64_t benchkit_read_fpcr(void) {
#if defined(__aarch64__)
    uint64_t v;
    __asm__ volatile("mrs %0, fpcr" : "=r"(v));
    return v;
#else
    return 0;
#endif
}

void benchkit_write_fpcr(uint64_t value) {
#if defined(__aarch64__)
    __asm__ volatile("msr fpcr, %0" : : "r"(value));
#else
    (void)value;
#endif
}
