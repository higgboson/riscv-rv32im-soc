// sw_perm.c - the Ascon permutation in software, shared by sw_aead.c and sw_hash.c

#define ASCON_INLINE_PERM  0
#define ASCON_UNROLL_LOOPS 0
#include "ascon-c/aead/permutations.c"
