// task_probe.c — dump everything the iOS kernel can see about a task,
// to find which per-task field makes chroot vs iOS-native diverge for AGX USC heap.
// Build for iOS arm64 (native iOS process — has trustcache-level access to other PIDs):
//   clang -arch arm64 -mios-version-min=16.0 -o task_probe misc/task_probe.c
// Sign + trustcache via the project's entitlements before deploying.
//
// Usage: task_probe <pid>
// Run against (a) chroot WindowServer pid, (b) iosblit pid, (c) itself, and diff.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <bsm/audit.h>

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
extern int csops_audittoken(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, audit_token_t *token);

#define CS_OPS_STATUS              0
#define CS_OPS_PIDPATH             4
#define CS_OPS_CDHASH              5
#define CS_OPS_PIDOFFSET           6
#define CS_OPS_ENTITLEMENTS_BLOB   7
#define CS_OPS_BLOB               10
#define CS_OPS_IDENTITY           11
#define CS_OPS_TEAMID             14
#define CS_OPS_DER_ENTITLEMENTS_BLOB 18

#define CS_VALID                   0x00000001
#define CS_ADHOC                   0x00000002
#define CS_GET_TASK_ALLOW          0x00000004
#define CS_INSTALLER               0x00000008
#define CS_FORCED_LV               0x00000010
#define CS_INVALID_ALLOWED         0x00000020
#define CS_HARD                    0x00000100
#define CS_KILL                    0x00000200
#define CS_CHECK_EXPIRATION        0x00000400
#define CS_RESTRICT                0x00000800
#define CS_ENFORCEMENT             0x00001000
#define CS_REQUIRE_LV              0x00002000
#define CS_ENTITLEMENTS_VALIDATED  0x00004000
#define CS_NVRAM_UNRESTRICTED      0x00008000
#define CS_RUNTIME                 0x00010000
#define CS_LINKER_SIGNED           0x00020000
#define CS_EXEC_SET_HARD           0x00100000
#define CS_EXEC_SET_KILL           0x00200000
#define CS_EXEC_SET_ENFORCEMENT    0x00400000
#define CS_EXEC_INHERIT_SIP        0x00800000
#define CS_KILLED                  0x01000000
#define CS_DYLD_PLATFORM           0x02000000
#define CS_PLATFORM_BINARY         0x04000000
#define CS_PLATFORM_PATH           0x08000000
#define CS_DEBUGGED                0x10000000
#define CS_SIGNED                  0x20000000
#define CS_DEV_CODE                0x40000000
#define CS_DATAVAULT_CONTROLLER    0x80000000

static void dump_cs_flags(uint32_t flags) {
    printf("  raw=0x%08x\n", flags);
    #define F(x) if (flags & x) printf("  -> " #x "\n")
    F(CS_VALID); F(CS_ADHOC); F(CS_GET_TASK_ALLOW); F(CS_INSTALLER);
    F(CS_FORCED_LV); F(CS_INVALID_ALLOWED);
    F(CS_HARD); F(CS_KILL); F(CS_CHECK_EXPIRATION); F(CS_RESTRICT);
    F(CS_ENFORCEMENT); F(CS_REQUIRE_LV); F(CS_ENTITLEMENTS_VALIDATED);
    F(CS_NVRAM_UNRESTRICTED); F(CS_RUNTIME); F(CS_LINKER_SIGNED);
    F(CS_EXEC_SET_HARD); F(CS_EXEC_SET_KILL); F(CS_EXEC_SET_ENFORCEMENT);
    F(CS_EXEC_INHERIT_SIP); F(CS_KILLED); F(CS_DYLD_PLATFORM);
    F(CS_PLATFORM_BINARY); F(CS_PLATFORM_PATH); F(CS_DEBUGGED);
    F(CS_SIGNED); F(CS_DEV_CODE); F(CS_DATAVAULT_CONTROLLER);
    #undef F
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <pid>\n", argv[0]); return 1; }
    pid_t pid = atoi(argv[1]);

    printf("==================== PID %d ====================\n", pid);

    // 1) executable path
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int n = proc_pidpath(pid, path, sizeof path);
    printf("\n[1] proc_pidpath: %s\n", n > 0 ? path : "(failed)");

    // 2) kinfo_proc via sysctl (no special entitlement needed)
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc kp; size_t sz = sizeof kp;
    printf("\n[2] kinfo_proc (sysctl):\n");
    if (sysctl(mib, 4, &kp, &sz, NULL, 0) == 0) {
        printf("  p_comm:        %s\n", kp.kp_proc.p_comm);
        printf("  p_pid:         %d\n", kp.kp_proc.p_pid);
        printf("  p_oppid:       %d\n", kp.kp_eproc.e_ppid);
        printf("  p_flag:        0x%x   (P_LP64=0x4 P_TRACED=0x800 P_EXEC=0x20000)\n",
               kp.kp_proc.p_flag);
        printf("  cr_uid:        %u\n", kp.kp_eproc.e_ucred.cr_uid);
        printf("  e_pcred ruid:  %u  rgid: %u\n", kp.kp_eproc.e_pcred.p_ruid, kp.kp_eproc.e_pcred.p_rgid);
        printf("  e_pcred svuid: %u  svgid: %u\n", kp.kp_eproc.e_pcred.p_svuid, kp.kp_eproc.e_pcred.p_svgid);
        printf("  e_pgid:        %d\n", kp.kp_eproc.e_pgid);
        printf("  e_xsize:       %d\n", kp.kp_eproc.e_xsize);
    } else perror("  sysctl");

    // 3) BSD info via proc_pidinfo
    printf("\n[3] proc_pidinfo PROC_PIDTBSDINFO:\n");
    struct proc_bsdinfo bi;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) == sizeof bi) {
        printf("  pbi_flags:     0x%x\n", bi.pbi_flags);
        printf("  pbi_status:    %u\n", bi.pbi_status);
        printf("  pbi_xstatus:   %u\n", bi.pbi_xstatus);
        printf("  pbi_pid:       %u\n", bi.pbi_pid);
        printf("  pbi_ppid:      %u\n", bi.pbi_ppid);
        printf("  pbi_uid:       %u\n", bi.pbi_uid);
        printf("  pbi_gid:       %u\n", bi.pbi_gid);
        printf("  pbi_ruid:      %u\n", bi.pbi_ruid);
        printf("  pbi_rgid:      %u\n", bi.pbi_rgid);
        printf("  pbi_svuid:     %u\n", bi.pbi_svuid);
        printf("  pbi_svgid:     %u\n", bi.pbi_svgid);
        printf("  pbi_nice:      %d\n", bi.pbi_nice);
        printf("  pbi_start_tvsec: %llu\n", bi.pbi_start_tvsec);
        printf("  pbi_name:      '%s'\n", bi.pbi_name);
        printf("  pbi_comm:      '%s'\n", bi.pbi_comm);
    } else printf("  (failed errno=%d %s)\n", errno, strerror(errno));

    // 4) PROC_PIDT_SHORTBSDINFO — has pbsi_flags (PROC_FLAG_LP64 / PROC_FLAG_PA_TRANSLATED etc)
    printf("\n[4] proc_pidinfo PROC_PIDT_SHORTBSDINFO:\n");
    struct proc_bsdshortinfo sbi;
    if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &sbi, sizeof sbi) == sizeof sbi) {
        printf("  pbsi_flags:    0x%x\n", sbi.pbsi_flags);
        printf("    -> bit set decode:\n");
        // P_TRANSLATED=0x20000, P_LP64=0x4, PROC_FLAG_PA_TRANSLATED=0x80000
        #define PF(name, val) if (sbi.pbsi_flags & (val)) printf("       " name " (0x%x)\n", val)
        PF("P_SUGID",        0x100);
        PF("P_LP64",         0x4);
        PF("P_TRANSLATED",   0x20000);
        PF("P_EXEC",         0x20000);
        PF("P_INVFORK",      0x10);
        PF("PROC_FLAG_LP64", 0x10);
        PF("PROC_FLAG_SYSTEM",       0x40);
        PF("PROC_FLAG_TRACED",       0x80);
        PF("PROC_FLAG_INEXIT",       0x100);
        PF("PROC_FLAG_PPWAIT",       0x200);
        PF("PROC_FLAG_LP64",         0x400);
        PF("PROC_FLAG_SLEADER",      0x800);
        PF("PROC_FLAG_CTTY",         0x1000);
        PF("PROC_FLAG_CONTROLT",     0x2000);
        PF("PROC_FLAG_THCWD",        0x4000);
        PF("PROC_FLAG_PA_TRANSLATED",0x80000);
        PF("PROC_FLAG_PSUGID",       0x100000);
        PF("PROC_FLAG_EXEC",         0x200000);
        PF("PROC_FLAG_DARWINBG",     0x8000);
        #undef PF
        printf("  pbsi_status:   %u\n", sbi.pbsi_status);
        printf("  pbsi_uid:      %u\n", sbi.pbsi_uid);
        printf("  pbsi_gid:      %u\n", sbi.pbsi_gid);
        printf("  pbsi_pgid:     %u\n", sbi.pbsi_pgid);
        printf("  pbsi_ruid:     %u\n", sbi.pbsi_ruid);
        printf("  pbsi_rgid:     %u\n", sbi.pbsi_rgid);
        printf("  pbsi_svuid:    %u\n", sbi.pbsi_svuid);
        printf("  pbsi_svgid:    %u\n", sbi.pbsi_svgid);
    } else printf("  (failed errno=%d %s)\n", errno, strerror(errno));

    // 5) CS_OPS_STATUS
    printf("\n[5] csops CS_OPS_STATUS (code-signing flags):\n");
    uint32_t cs_flags = 0;
    if (csops(pid, CS_OPS_STATUS, &cs_flags, sizeof cs_flags) == 0)
        dump_cs_flags(cs_flags);
    else
        printf("  (failed errno=%d %s)\n", errno, strerror(errno));

    // 6) CS_OPS_TEAMID
    printf("\n[6] csops CS_OPS_TEAMID:\n");
    char teamid[256] = {0};
    if (csops(pid, CS_OPS_TEAMID, teamid, sizeof teamid) == 0)
        printf("  '%s'\n", teamid);
    else
        printf("  (failed errno=%d %s) -- usually means no TeamID (ad-hoc)\n", errno, strerror(errno));

    // 7) CS_OPS_IDENTITY
    printf("\n[7] csops CS_OPS_IDENTITY:\n");
    char identity[256] = {0};
    if (csops(pid, CS_OPS_IDENTITY, identity, sizeof identity) == 0)
        printf("  '%s'\n", identity);
    else
        printf("  (failed errno=%d %s)\n", errno, strerror(errno));

    // 8) CS_OPS_CDHASH (20 bytes)
    printf("\n[8] csops CS_OPS_CDHASH:\n");
    uint8_t cdhash[20] = {0};
    if (csops(pid, CS_OPS_CDHASH, cdhash, sizeof cdhash) == 0) {
        printf("  ");
        for (int i = 0; i < 20; i++) printf("%02x", cdhash[i]);
        printf("\n");
    } else printf("  (failed errno=%d %s)\n", errno, strerror(errno));

    // 9) audit token (the kernel uses this for many decisions)
    printf("\n[9] csops_audittoken (audit_token):\n");
    audit_token_t at = {0};
    uint32_t dummy = 0;
    if (csops_audittoken(pid, CS_OPS_STATUS, &dummy, sizeof dummy, &at) == 0) {
        printf("  raw: ");
        for (int i = 0; i < 8; i++) printf("0x%08x ", at.val[i]);
        printf("\n");
        printf("  auid=%u  euid=%u  egid=%u  ruid=%u  rgid=%u  pid=%u  asid=%u  pidversion=%u\n",
               at.val[0], at.val[1], at.val[2], at.val[3], at.val[4], at.val[5], at.val[6], at.val[7]);
    } else printf("  (failed errno=%d %s)\n", errno, strerror(errno));

    // 10) entitlements blob (the big one — what kernel sees on entitlement checks)
    printf("\n[10] csops CS_OPS_ENTITLEMENTS_BLOB:\n");
    static uint8_t ent_buf[65536] = {0};
    if (csops(pid, CS_OPS_ENTITLEMENTS_BLOB, ent_buf, sizeof ent_buf) == 0) {
        // SuperBlob header: 4-byte magic + 4-byte length, both big-endian
        uint32_t magic = ntohl(*(uint32_t *)ent_buf);
        uint32_t length = ntohl(*(uint32_t *)(ent_buf + 4));
        printf("  magic=0x%08x  length=%u\n", magic, length);
        if (length > 8 && length < sizeof ent_buf) {
            const char *xml = (const char *)(ent_buf + 8);
            // print first 600 bytes of plist text
            size_t n_xml = length - 8; if (n_xml > 600) n_xml = 600;
            printf("  --- XML (first %zu bytes) ---\n", n_xml);
            fwrite(xml, 1, n_xml, stdout);
            printf("\n  --- end XML ---\n");
            printf("  XML total bytes: %u\n", length - 8);
        }
    } else if (errno == EINVAL) {
        printf("  (EINVAL — no entitlements blob; check DER blob)\n");
        if (csops(pid, CS_OPS_DER_ENTITLEMENTS_BLOB, ent_buf, sizeof ent_buf) == 0)
            printf("  DER blob length=%u\n", ntohl(*(uint32_t *)(ent_buf + 4)));
        else
            printf("  DER blob also failed: errno=%d %s\n", errno, strerror(errno));
    } else printf("  (failed errno=%d %s)\n", errno, strerror(errno));

    // 11) PROC_PIDTASKINFO — task-level (cpu/mem)
    printf("\n[11] proc_pidinfo PROC_PIDTASKINFO:\n");
    struct proc_taskinfo ti;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof ti) == sizeof ti) {
        printf("  virtual_size:   0x%llx (%llu MB)\n", ti.pti_virtual_size, ti.pti_virtual_size >> 20);
        printf("  resident_size:  0x%llx (%llu MB)\n", ti.pti_resident_size, ti.pti_resident_size >> 20);
        printf("  threadnum:      %d\n", ti.pti_threadnum);
        printf("  priority:       %d\n", ti.pti_priority);
        printf("  policy:         %d\n", ti.pti_policy);
        printf("  faults:         %d\n", ti.pti_faults);
        printf("  pageins:        %d\n", ti.pti_pageins);
    } else printf("  (failed errno=%d %s)\n", errno, strerror(errno));

    return 0;
}
