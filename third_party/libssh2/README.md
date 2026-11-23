# Vendored libssh2 source override

`crypto.c` here replaces libssh2's `src/crypto.c` and is compiled instead of the
upstream one (see `addLibssh2` in the top-level `build.zig`). Everything else
comes straight from the pinned `libssh2_upstream` tarball in `build.zig.zon`.

## Patch

libssh2 1.11.1's mbedTLS backend keeps a **process-global** entropy/CTR_DRBG
pair and draws every outgoing SSH packet's padding from it. With one session per
upload thread, those calls race on the same DRBG state and corrupt memory. On
Windows this showed up as `Illegal instruction`, `STATUS_HEAP_CORRUPTION` and
segfaults inside `_libssh2_transport_send` → `_libssh2_random` and
`libssh2_session_free` (2 of 5 eight-thread runs of an 8000-file sync failed;
0 of 5 with a single thread).

The patch compiles the upstream mbedTLS backend under a private symbol and
provides `_libssh2_mbedtls_random` as a wrapper around a process-wide
`atomic_flag` spinlock. Handshake-time public-key operations also use the DRBG,
so `SshSession.init` additionally serializes connect/handshake/authentication
(`connect_mutex` in `src/ssh.zig`).

## Keeping it in sync

When bumping `libssh2_upstream` in `build.zig.zon`, re-copy upstream
`src/crypto.c` next to the patched mbedTLS branch, and re-check:

- the `_libssh2_mbedtls_random` prototype in `src/mbedtls.h`,
- that no other code path uses the DRBG after the handshake except packet
  padding (re-run the parallel stress test if in doubt).
