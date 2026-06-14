// pactest — tiny arm64e PAC sanity check. Calls pacda/pacia with known inputs and prints
// before/after. If high bits != 0 after sign, the process's PAC keys are functional.
// Build as arm64e and ldid-sign with entitlements; run both directly (iOS environment) and
// inside the chroot to isolate where PAC keys break.
#include <stdio.h>
#include <stdint.h>
#include <ptrauth.h>

int main(int argc, char **argv) {
    // Two arbitrary "pointers" + a discriminator (mimicking how the Block runtime signs).
    void *p1 = (void *)0x0000000123456789ULL;
    void *p2 = (void *)0x00000001abcdef00ULL;
    uintptr_t disc_da = 0x6ae1000000000000ULL | (uintptr_t)&p1;  // disc for DA, with the 0x6ae1 modifier
    uintptr_t disc_ia = (uintptr_t)&p2;                          // disc for IA

    void *s_da = ptrauth_sign_unauthenticated(p1, ptrauth_key_asda, disc_da);
    void *s_ia = ptrauth_sign_unauthenticated(p2, ptrauth_key_asia, disc_ia);
    void *s_db = ptrauth_sign_unauthenticated(p1, ptrauth_key_asdb, disc_da);
    void *s_ib = ptrauth_sign_unauthenticated(p2, ptrauth_key_asib, disc_ia);

    printf("PACTEST argc=%d\n", argc);
    printf("  pacda(%p, disc=%#llx) -> %p   delta=%#llx\n",
           p1, (unsigned long long)disc_da, s_da,
           (unsigned long long)((uintptr_t)s_da ^ (uintptr_t)p1));
    printf("  pacia(%p, disc=%#llx) -> %p   delta=%#llx\n",
           p2, (unsigned long long)disc_ia, s_ia,
           (unsigned long long)((uintptr_t)s_ia ^ (uintptr_t)p2));
    printf("  pacdb(%p, disc=%#llx) -> %p   delta=%#llx\n",
           p1, (unsigned long long)disc_da, s_db,
           (unsigned long long)((uintptr_t)s_db ^ (uintptr_t)p1));
    printf("  pacib(%p, disc=%#llx) -> %p   delta=%#llx\n",
           p2, (unsigned long long)disc_ia, s_ib,
           (unsigned long long)((uintptr_t)s_ib ^ (uintptr_t)p2));
    printf("VERDICT: %s\n",
           ((uintptr_t)s_da == (uintptr_t)p1) ? "PAC KEYS ARE ZERO (pacda no-op)" : "PAC KEYS WORK");
    return 0;
}
