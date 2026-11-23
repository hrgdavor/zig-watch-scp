/* Copyright (C) Viktor Szakats
 *
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Patched copy of libssh2 1.11.1 `src/crypto.c` (the version pinned by the
 * `libssh2_upstream` dependency in build.zig.zon). Only the mbedTLS branch is
 * changed; every other backend below is untouched and can be used as before.
 *
 * Why: libssh2's mbedTLS backend keeps one process-global entropy/CTR_DRBG
 * pair (`_libssh2_mbedtls_entropy`, `_libssh2_mbedtls_ctr_drbg`), and every
 * outgoing SSH packet draws its padding from it through `_libssh2_random()`
 * (see src/transport.c). When several sessions run in several threads, those
 * calls race on the DRBG state and corrupt memory: observed here as SIGILL,
 * STATUS_HEAP_CORRUPTION and crashes inside _libssh2_transport_send and
 * session_free. Handshake-time public-key operations use the same DRBG, so
 * src/ssh.zig additionally serializes connect + handshake + authentication.
 *
 * The wrapper below only covers packet padding, which is the call that runs
 * concurrently for the whole lifetime of parallel upload sessions.
 */

#define LIBSSH2_CRYPTO_C
#include "libssh2_priv.h"

#if defined(LIBSSH2_MBEDTLS)

#include <stdatomic.h>

/* Compile the upstream implementation under a private name so that the public
 * RNG entry point (declared in mbedtls.h) can be replaced by a safe wrapper. */
#define _libssh2_mbedtls_random _libssh2_mbedtls_random_unlocked
#include "mbedtls.c"
#undef _libssh2_mbedtls_random

static atomic_flag ss_random_lock = ATOMIC_FLAG_INIT;

int
_libssh2_mbedtls_random(unsigned char *buf, size_t len)
{
    int rc;
    while(atomic_flag_test_and_set_explicit(&ss_random_lock,
                                            memory_order_acquire)) {
        /* The lock covers a single DRBG output, so spinning is cheaper than
         * a kernel wait. */
    }
    rc = _libssh2_mbedtls_random_unlocked(buf, len);
    atomic_flag_clear_explicit(&ss_random_lock, memory_order_release);
    return rc;
}

#elif defined(LIBSSH2_OPENSSL) || defined(LIBSSH2_WOLFSSL)
#include "openssl.c"
#elif defined(LIBSSH2_LIBGCRYPT)
#include "libgcrypt.c"
#elif defined(LIBSSH2_OS400QC3)
#include "os400qc3.c"
#elif defined(LIBSSH2_WINCNG)
#include "wincng.c"
#endif
