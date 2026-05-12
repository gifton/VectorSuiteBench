// BenchKitC — small C bridge for inline assembly that Swift can't express.
//
// Currently only used for the AArch64 FPCR (Floating-Point Control Register)
// read/write. Apple Silicon's FPCR controls FZ (Flush-to-Zero) and DN
// (Default NaN) behavior. Capturing FPCR at run start ensures the run
// manifest records the denormals policy under which measurements were taken.

#ifndef BENCHKIT_C_H
#define BENCHKIT_C_H

#include <stdint.h>

/// Read the current FPCR. Returns 0 on non-AArch64 platforms.
uint64_t benchkit_read_fpcr(void);

/// Write a new FPCR value. No-op on non-AArch64 platforms.
void benchkit_write_fpcr(uint64_t value);

#endif
