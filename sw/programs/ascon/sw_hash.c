// sw_hash.c - Ascon-Hash256 in software (ascon-c/hash, unmodified, see sw_aead.c)

#define ASCON_INLINE_PERM  0
#define ASCON_UNROLL_LOOPS 0
#include "ascon-c/hash/hash.c"
