@import CydiaSubstrate;
@import Foundation;
@import Darwin;
#include <stdarg.h>
#include <time.h>
#include <syslog.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

// The rootless iOS 16 Theos SDK used by this project omits xpc/xpc.h.  This
// is the exact public C ABI needed by the UUID-locked reply observer.
extern void *xpc_data_create(const void *bytes, size_t length);

// NOTE: do NOT take an ObjC block here. Under -fobjc-arc the on-device lld
// arm64e build mis-signs the block's metadata pointer, so ARC's objc_storeStrong
// on the block parameter PAC-faults in this dylib's %ctor (crashes MTLCompilerService
// on inject -> deadlocks the whole Metal/WindowServer path). Patch the word directly.
static void PatchInstruction(uint32_t *addr, uint32_t value) {
    vm_protect(mach_task_self(), (vm_address_t)addr, sizeof(uint32_t), false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    *addr = value;
    vm_protect(mach_task_self(), (vm_address_t)addr, sizeof(uint32_t), false, PROT_READ | PROT_EXEC);
}

// ─── AGXCompilerCore verifyLoweredIR bypass ─────────────────────────────
//
// The macOS-13.4 AIR that chroot WindowServer hands to MTLCompilerService
// uses `air.fract.v3f16` (fract on half3). Inside AGXCompilerCore an
// optimisation pass renames it to the AGX-internal name
// `agx.air.fract.v3f16.fast` (the same rename that exists for
// `air.fast_fract.v2f32` etc.). But the dispatch table built by
// `AGCLLVMAirBuiltinsMap::insertBuiltinReplacementsBase` only has keys
// `"fract"` and `"fast_fract"` — there's no entry for the typed-suffix
// `fract.v3f16.fast` form. `AGCLLVMUserObject::verifyLoweredIR()` then
// iterates the module's function list, finds the unlowered declaration
// whose name still contains "air.", logs
//   "Encountered unlowered function call to agx.air.fract.v3f16.fast"
// via _os_log_fault_impl, and the surrounding compile pipeline captures
// that log into the abort_with_payload(13, 4, …) reason string that CA
// turns into "Metal failed to build render pipeline" → WindowServer dies.
//
// Crucially: `AGCLLVMAirBuiltins::buildFastFract` IS implemented (and
// the v3f16 path inside it is the trivial `x - floor(x)` lowering — the
// f32-specific post-clamp is skipped by `cmp w10, #0x2 ; b.ne epilogue`
// at the start of its body). So if we silence the verifier's complaint
// about the rename, downstream codegen will either emit a working
// lowering itself or carry the call as a declaration the GPU runtime
// resolves via builtin tables — either way, the host-side abort goes
// away and we get to observe the actual GPU behaviour.
//
// The verifier function's symbol is stripped from the iOS-side
// AGXCompilerCore so MSFindSymbol can't locate it directly. Instead we
// anchor on the exported `_AIRNTGetVersion` (one of 33 surviving public
// `AIRNT*` symbols) and use the static delta measured against the
// iPad13,6 16.3.1 (20D67) Symbols build:
//
//   verifier = AIRNTGetVersion - 0x5fb78
//
// (verifier @ 0x1be30999c, AIRNTGetVersion @ 0x1be369514 in that build).
//
// Patch is one instruction: `pacibsp` at function entry → `ret`. The
// caller's BL set LR to the next instruction in the caller; no stack
// frame has been built yet, so simply returning to LR is correct and
// avoids the verifier's iteration over the module's function list.
//
// If the byte at the computed address is not `pacibsp` (0xd503237f),
// the iOS AGXCompilerCore has changed and the anchor needs re-checking;
// we abort instead of silently corrupting an unknown instruction.
// ─── AGX renamer fix: skip the "agx." prepend ─────────────────────────────
//
// `AGCLLVMUserObject::linkMetalRuntime(bool)` walks the module's
// runtime-shim function list and for each function builds a renamed
// declaration `"agx." + originalName + ".fast"`, replaces uses, and
// hands the new declaration to the next pass. For an originalName like
// `air.fract.v3f16` the produced name `agx.air.fract.v3f16.fast` is
// never matched by `AGCLLVMAirBuiltins::replaceBuiltins`'s dispatcher
// (which only accepts the "air." prefix), so the call survives into
// `AGCLLVMUserObject::verifyLoweredIR` as an unlowered declaration and
// the compile aborts.
//
// The rename is implemented as a `std::string::insert(0, "agx.")` call
// — instruction `bl __ZNSt3__112basic_string…::insert(pos, str)` that
// follows the `add x2, x2, #… ; "agx."` adrp pair. If we NOP that one
// BL the agx-prefix step is skipped: the rename becomes
// `"" + originalName + ".fast" = "air.fract.v3f16.fast"`, the
// dispatcher's findPrefix accepts the "air." prefix, splits at the
// first dot of the remainder into ("fract", "v3f16.fast"), and the
// "fract" key already resolves to `AGCLLVMAirBuiltins::buildFract`,
// which lowers via the operand's runtime LLVM type — the trailing
// ".fast" in the name is just a suffix on the Function name and is
// ignored by buildFract (it reads the actual Value type, not the
// Function name).
//
// The patch site is found by anchoring on the surviving export
// `_AIRNTGetVersion` (one of the 33 public AIRNT* symbols). Delta
// measured against the iPad13,6 16.3.1 (20D67) DSC:
//   bl insert @ 0x1be243b70
//   _AIRNTGetVersion @ 0x1be369514
//   delta = -0x1259a4
//
// Validation: the instruction at the patch site must be a BL (opcode
// bits 26..31 == 0b100101 == 0x25). If the iOS AGXCompilerCore has
// changed and the byte is not a BL, we leave the original behaviour
// alone instead of corrupting some unknown instruction.
// Sandboxed XPC services (like MTLCompilerService under its
// `seatbelt-profiles=[MTLCompilerService]` profile) cannot create files
// outside /private/var/mobile, so the old fopen("/tmp/...") path silently
// failed. Try multiple destinations: a file under /var/mobile (writable
// by the XPC service's sandbox), syslog (tagged "MTLBypass"), and stderr.
static void MTLPatchLog(const char *fmt, ...) {
    static int once = 0;
    if (!once) { openlog("MTLBypass", LOG_PID | LOG_NDELAY, LOG_USER); once = 1; }
    char buf[512];
    pid_t pid = getpid();
    time_t now = time(NULL);
    struct tm tm; localtime_r(&now, &tm);
    int hdr = snprintf(buf, sizeof(buf),
        "[%04d-%02d-%02d %02d:%02d:%02d pid=%d] ",
        tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday,
        tm.tm_hour, tm.tm_min, tm.tm_sec, pid);
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf + hdr, sizeof(buf) - hdr, fmt, ap);
    va_end(ap);
    syslog(LOG_NOTICE, "%s", buf + hdr);
    fprintf(stderr, "#### MTLBypass %s\n", buf + hdr);
    fflush(stderr);
    // Try several paths until one is writable from the sandbox.
    static const char *paths[] = {
        "/var/mobile/Library/Logs/mtl_compiler_patch.log",
        "/var/mobile/mtl_compiler_patch.log",
        "/var/jb/var/mobile/mtl_compiler_patch.log",
        "/tmp/mtl_compiler_patch.log",
        NULL,
    };
    for (int i = 0; paths[i]; i++) {
        FILE *f = fopen(paths[i], "a");
        if (f) {
            fputs(buf, f);
            fputc('\n', f);
            fclose(f);
            return;
        }
    }
}

// MTLCompilerService runs in the iOS host namespace, while the macOS Metal
// client constructs its clang module-cache path from the chroot's
// /var/folders tree.  Sharing that tree with bindfs is insufficient: the
// service's seatbelt evaluates the original /var/folders pathname and rejects
// creation of monolithic_metal.pcm with EPERM.  Adapt only paths below a
// com.apple.metalfe cache directory to the rootless mobile tree.  That exact
// namespace is runtime-confirmed writable by this process because
// MTLPatchLog's /var/jb/var/mobile log survives every compiler request;
// /var/mobile/Library/Caches was separately tried and returned EPERM.  This
// preserves the file operation and its real result; it does not
// turn a failed check into success or synthesize compiler output.
//
// Runtime witness before this adapter (vscode.log, 2026-07-28):
//   unable to open output file '/var/folders/.../com.apple.metalfe/
//   F0DURH57MFZX/monolithic_metal.pcm': 'Operation not permitted'
//
// The wrappers also log each translated operation and errno so a future path
// or libc call-site change fails visibly rather than becoming a silent cache
// bypass.
static const char *kMetalCacheRoot =
    "/var/jb/var/mobile/Library/Caches/macws-metalfe";
static const char *kMetalCacheMarker = "/com.apple.metalfe/";

static bool TranslateMetalCachePath(const char *path,
                                    char translated[PATH_MAX]) {
    if (!path || strncmp(path, "/var/folders/zz/", 16) != 0) return false;
    const char *marker = strstr(path, kMetalCacheMarker);
    if (!marker) return false;
    const char *suffix = marker + strlen(kMetalCacheMarker);
    int n = snprintf(translated, PATH_MAX, "%s/%s", kMetalCacheRoot, suffix);
    return n > 0 && n < PATH_MAX;
}

static int (*OrigOpen)(const char *, int, ...) = NULL;
static int (*OrigOpenAt)(int, const char *, int, ...) = NULL;
static int (*OrigStat)(const char *, struct stat *) = NULL;
static int (*OrigMkdir)(const char *, mode_t) = NULL;
static int (*OrigMkdirAt)(int, const char *, mode_t) = NULL;
static int (*OrigRename)(const char *, const char *) = NULL;
static int (*OrigRenameAt)(int, const char *, int, const char *) = NULL;
static int (*OrigUnlink)(const char *) = NULL;
static int (*OrigUnlinkAt)(int, const char *, int) = NULL;

static int MetalCacheOpen(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap);
    }
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    const char *actual = changed ? mapped : path;
    int result = (flags & O_CREAT) ? OrigOpen(actual, flags, mode)
                                   : OrigOpen(actual, flags);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache open flags=%#x '%s' -> '%s' result=%d errno=%d",
                             flags, path, actual, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheOpenAt(int fd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap);
    }
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    const char *actual = changed ? mapped : path;
    int result = (flags & O_CREAT) ? OrigOpenAt(fd, actual, flags, mode)
                                   : OrigOpenAt(fd, actual, flags);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache openat fd=%d flags=%#x '%s' -> '%s' result=%d errno=%d",
                             fd, flags, path, actual, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheStat(const char *path, struct stat *st) {
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    const char *actual = changed ? mapped : path;
    int result = OrigStat(actual, st);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache stat '%s' -> '%s' result=%d errno=%d",
                             path, actual, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheMkdir(const char *path, mode_t mode) {
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    int result = OrigMkdir(changed ? mapped : path, mode);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache mkdir '%s' -> '%s' result=%d errno=%d",
                             path, mapped, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheMkdirAt(int fd, const char *path, mode_t mode) {
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    int result = OrigMkdirAt(fd, changed ? mapped : path, mode);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache mkdirat fd=%d '%s' -> '%s' result=%d errno=%d",
                             fd, path, mapped, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheRename(const char *from, const char *to) {
    char mappedFrom[PATH_MAX], mappedTo[PATH_MAX];
    bool changedFrom = TranslateMetalCachePath(from, mappedFrom);
    bool changedTo = TranslateMetalCachePath(to, mappedTo);
    int result = OrigRename(changedFrom ? mappedFrom : from,
                            changedTo ? mappedTo : to);
    int saved = errno;
    if (changedFrom || changedTo)
        MTLPatchLog("metal-cache rename '%s' -> '%s' result=%d errno=%d",
                    changedFrom ? mappedFrom : from,
                    changedTo ? mappedTo : to,
                    result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheRenameAt(int fromFD, const char *from,
                              int toFD, const char *to) {
    char mappedFrom[PATH_MAX], mappedTo[PATH_MAX];
    bool changedFrom = TranslateMetalCachePath(from, mappedFrom);
    bool changedTo = TranslateMetalCachePath(to, mappedTo);
    int result = OrigRenameAt(fromFD, changedFrom ? mappedFrom : from,
                              toFD, changedTo ? mappedTo : to);
    int saved = errno;
    if (changedFrom || changedTo)
        MTLPatchLog("metal-cache renameat '%s' -> '%s' result=%d errno=%d",
                    changedFrom ? mappedFrom : from,
                    changedTo ? mappedTo : to,
                    result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheUnlink(const char *path) {
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    int result = OrigUnlink(changed ? mapped : path);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache unlink '%s' -> '%s' result=%d errno=%d",
                             path, mapped, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static int MetalCacheUnlinkAt(int fd, const char *path, int flags) {
    char mapped[PATH_MAX];
    bool changed = TranslateMetalCachePath(path, mapped);
    int result = OrigUnlinkAt(fd, changed ? mapped : path, flags);
    int saved = errno;
    if (changed) MTLPatchLog("metal-cache unlinkat fd=%d '%s' -> '%s' result=%d errno=%d",
                             fd, path, mapped, result, result < 0 ? saved : 0);
    errno = saved;
    return result;
}

static void InstallMetalCachePathAdapter(void) {
    // Parent exists in the stock mobile container; errors are left visible in
    // the operation logs below.  The benchmark setup creates the final root
    // once, while translated mkdir calls create per-compiler hash directories.
    mkdir(kMetalCacheRoot, 0755);
#define HOOK_LIBC(name, replacement, original) do { \
    void *symbol = dlsym(RTLD_DEFAULT, name); \
    if (symbol) MSHookFunction(symbol, (void *)(replacement), (void **)&(original)); \
} while (0)
    HOOK_LIBC("open", MetalCacheOpen, OrigOpen);
    HOOK_LIBC("openat", MetalCacheOpenAt, OrigOpenAt);
    HOOK_LIBC("stat", MetalCacheStat, OrigStat);
    HOOK_LIBC("mkdir", MetalCacheMkdir, OrigMkdir);
    HOOK_LIBC("mkdirat", MetalCacheMkdirAt, OrigMkdirAt);
    HOOK_LIBC("rename", MetalCacheRename, OrigRename);
    HOOK_LIBC("renameat", MetalCacheRenameAt, OrigRenameAt);
    HOOK_LIBC("unlink", MetalCacheUnlink, OrigUnlink);
    HOOK_LIBC("unlinkat", MetalCacheUnlinkAt, OrigUnlinkAt);
#undef HOOK_LIBC
    MTLPatchLog("metal-cache adapter installed root=%s open=%p openat=%p stat=%p mkdir=%p rename=%p unlink=%p",
                kMetalCacheRoot, OrigOpen, OrigOpenAt, OrigStat, OrigMkdir,
                OrigRename, OrigUnlink);
}

// The chroot's macOS Metal client sends source requests to the iOS-hosted
// MTLCompilerService.  Runtime LLDB at MTLCodeGenServiceBuildRequest captured
// the complete request ABI:
//
//   uint64_t sourceLength; uint64_t argumentLength;
//   char source[sourceLength]; padding-to-8; char arguments[argumentLength];
//
// The arguments omit a target platform.  Consequently the iOS service emits
// an iOS MTLB (header 0x0001/0x8200), which the unmodified macOS Metal loader
// rejects at MTLLibraryDataWithArchive::parseArchiveSync+680.  LLDB replacing
// the complete `-working-directory "..."` argument with
// `-active-platform=macos` plus length-preserving padding advanced the same
// request through the archive-format check and into real module compilation.
// The runtime adapter additionally requires the chroot-only /var/folders
// module-cache argument before making that replacement.  It then calls the
// original compiler entry point; no compiler result or loader validation is
// bypassed.
//
// MTLCompilerService 6D2CFE56-8D88-39AA-BC25-7FFE5058ED4E has two calls to
// the same service-vtable slot: __TEXT+0x25f0 when the hang timer is active,
// and __TEXT+0x2628 when MTL_HANG_TIMER_LENGTH_IN_SECONDS is less than one.
// Both are `blraaz x8` (0xd63f091f).  Patching only +0x25f0 produced a
// runtime-confirmed mixture of macOS MTLB headers (0x8001) and unadapted iOS
// headers (0x0001) in a cold Chromium shader-cache run.  Replacing both
// authenticated indirect calls with direct BLs avoids the arm64e
// Substrate-trampoline PAC failure while leaving the exported function itself
// untouched.
typedef uintptr_t (*MTLCodeGenServiceBuildRequestFn)(
    uintptr_t, uintptr_t, uintptr_t, void *, size_t, void *);
static MTLCodeGenServiceBuildRequestFn OrigMTLCodeGenServiceBuildRequest = NULL;
static uintptr_t StripPAC(const void *p);

static uint64_t MacWSFNV1a64(const void *data, size_t length) {
    const uint8_t *bytes = (const uint8_t *)data;
    uint64_t hash = UINT64_C(1469598103934665603);
    for (size_t i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

// Read-only compiler-result witness.  MTLCompilerService's exact executable
// reply block calls xpc_data_create at UUID-locked __TEXT+0x2770 with the
// compiler result bytes and length.  The adapter redirects only that BL here,
// records the returned container verbatim, then calls the real XPC API.  No
// result bytes or status are changed.
static void *MacWSCompilerReplyDataCreate(const void *bytes, size_t length) {
    static _Atomic uint32_t replySequence = 0;
    uint32_t sequence = atomic_fetch_add(&replySequence, 1) + 1;
    uint64_t hash = MacWSFNV1a64(bytes, length);
    uint8_t head[24] = {0};
    size_t headLength = length < sizeof(head) ? length : sizeof(head);
    if (bytes && headLength) memcpy(head, bytes, headLength);
    MTLPatchLog("compiler reply #%u length=%zu hash=%016llx head=%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x",
                sequence, length, (unsigned long long)hash,
                head[0], head[1], head[2], head[3],
                head[4], head[5], head[6], head[7],
                head[8], head[9], head[10], head[11],
                head[12], head[13], head[14], head[15],
                head[16], head[17], head[18], head[19],
                head[20], head[21], head[22], head[23]);

    if (bytes && length && sequence <= 64) {
        const char *directory = "/var/jb/var/mobile/mtlcompiler_replies";
        mkdir(directory, 0755);
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/reply-%d-%03u-%zu-%016llx.bin",
                 directory, getpid(), sequence, length,
                 (unsigned long long)hash);
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (fd >= 0) {
            const uint8_t *cursor = (const uint8_t *)bytes;
            size_t remaining = length;
            while (remaining) {
                ssize_t written = write(fd, cursor, remaining);
                if (written <= 0) break;
                cursor += written;
                remaining -= (size_t)written;
            }
            close(fd);
            MTLPatchLog("compiler reply #%u dump=%s written=%zu/%zu",
                        sequence, path, length - remaining, length);
        } else {
            MTLPatchLog("compiler reply #%u dump open failed path=%s errno=%d",
                        sequence, path, errno);
        }
    }
    return xpc_data_create(bytes, length);
}

static uintptr_t MacWSMTLCodeGenServiceBuildRequest(
    uintptr_t a0, uintptr_t a1, uintptr_t a2,
    void *request, size_t requestSize, void *a5) {
    static const char workingDirectoryPrefix[] = "-working-directory \"";
    static const char targetArgument[] = "-active-platform=macos";
    static _Atomic uint32_t requestSequence = 0;
    uint32_t sequence = atomic_fetch_add(&requestSequence, 1) + 1;
    if (sequence <= 256) {
        uint8_t head[16] = {0};
        size_t headLength = requestSize < sizeof(head)
            ? requestSize : sizeof(head);
        if (request && headLength) memcpy(head, request, headLength);
        MTLPatchLog("target adapter entry #%u requestType=%#llx total=%zu request=%p head=%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x-%02x%02x%02x%02x",
                    sequence, (unsigned long long)a2, requestSize, request,
                    head[0], head[1], head[2], head[3],
                    head[4], head[5], head[6], head[7],
                    head[8], head[9], head[10], head[11],
                    head[12], head[13], head[14], head[15]);
    }

    bool adapted = false;
    if (request && requestSize >= 16 && a2 == 0xd) {
        // Chromium's MSL requests use two closely related serializations.
        // Most are exactly 16 + source + 8-byte padding + arguments.  Others
        // declare the same source/argument lengths but are four bytes shorter
        // than that formula.  Both carry the literal compiler arguments, so
        // locate the two exact chroot-only tokens in the bounded request blob
        // instead of guessing which serializer produced it.
        static const char cacheMarker[] =
            "-fmodules-cache-path=\"/var/folders/zz/";
        uint8_t *bytes = (uint8_t *)request;
        size_t prefixLength = sizeof(workingDirectoryPrefix) - 1;
        size_t markerLength = sizeof(cacheMarker) - 1;
        size_t workingOffset = (size_t)-1;
        size_t cacheOffset = (size_t)-1;
        for (size_t i = 0; i + prefixLength <= requestSize; i++) {
            if (memcmp(bytes + i, workingDirectoryPrefix,
                       prefixLength) == 0) {
                workingOffset = i;
                break;
            }
        }
        for (size_t i = 0; i + markerLength <= requestSize; i++) {
            if (memcmp(bytes + i, cacheMarker, markerLength) == 0) {
                cacheOffset = i;
                break;
            }
        }
        if (workingOffset != (size_t)-1 && cacheOffset != (size_t)-1) {
            size_t closingQuote = workingOffset + prefixLength;
            while (closingQuote < requestSize &&
                   bytes[closingQuote] != '"') {
                closingQuote++;
            }
            size_t targetLength = sizeof(targetArgument) - 1;
            if (closingQuote < requestSize) {
                size_t tokenLength = closingQuote - workingOffset + 1;
                if (tokenLength >= targetLength) {
                    memcpy(bytes + workingOffset, targetArgument,
                           targetLength);
                    memset(bytes + workingOffset + targetLength, ' ',
                           tokenLength - targetLength);
                    adapted = true;
                }
            }
        }

        uint64_t sourceLength = 0, argumentLength = 0;
        memcpy(&sourceLength, bytes, sizeof(sourceLength));
        memcpy(&argumentLength, bytes + 8, sizeof(argumentLength));
        if (sourceLength <= requestSize - 16) {
            size_t hashLength = (size_t)sourceLength;
            if (hashLength && bytes[16 + hashLength - 1] == 0)
                hashLength--;
            uint64_t sourceHash = MacWSFNV1a64(bytes + 16, hashLength);
            uint64_t expectedSize =
                ((UINT64_C(16) + sourceLength + 7) & ~UINT64_C(7)) +
                argumentLength;
            long long layoutDelta = expectedSize <= LLONG_MAX
                ? (long long)expectedSize - (long long)requestSize
                : LLONG_MAX;
            MTLPatchLog("target adapter request=%p total=%zu source=%llu sourceHash=%016llx args=%llu layoutDelta=%lld workingOffset=%lld cacheOffset=%lld adapted=%d",
                        request, requestSize,
                        (unsigned long long)sourceLength,
                        (unsigned long long)sourceHash,
                        (unsigned long long)argumentLength, layoutDelta,
                        workingOffset == (size_t)-1 ? -1LL
                            : (long long)workingOffset,
                        cacheOffset == (size_t)-1 ? -1LL
                            : (long long)cacheOffset,
                        adapted);
        }
    }
    return OrigMTLCodeGenServiceBuildRequest
        ? OrigMTLCodeGenServiceBuildRequest(a0, a1, a2, request,
                                            requestSize, a5)
        : (uintptr_t)-1;
}

static void InstallMacOSMetalTargetAdapter(void) {
    static const uint8_t expectedUUID[16] = {
        0x6d, 0x2c, 0xfe, 0x56, 0x8d, 0x88, 0x39, 0xaa,
        0xbc, 0x25, 0x7f, 0xfe, 0x50, 0x58, 0xed, 0x4e,
    };
    const struct mach_header_64 *mh = NULL;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name,
                "MTLCompilerService.xpc/MTLCompilerService")) {
            mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
            break;
        }
    }
    if (!mh || mh->magic != MH_MAGIC_64 || mh->filetype != MH_EXECUTE) {
        MTLPatchLog("target adapter: executable Mach-O header unavailable mh=%p magic=%#x filetype=%#x",
                    mh, mh ? mh->magic : 0, mh ? mh->filetype : 0);
        return;
    }
    const struct load_command *lc =
        (const struct load_command *)((const uint8_t *)mh + sizeof(*mh));
    bool uuidMatches = false;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_UUID) {
            const struct uuid_command *uc = (const struct uuid_command *)lc;
            uuidMatches = memcmp(uc->uuid, expectedUUID, 16) == 0;
            break;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!uuidMatches) {
        MTLPatchLog("target adapter: MTLCompilerService UUID mismatch");
        return;
    }

    OrigMTLCodeGenServiceBuildRequest =
        (MTLCodeGenServiceBuildRequestFn)dlsym(
            RTLD_DEFAULT, "MTLCodeGenServiceBuildRequest");
    static const uintptr_t callOffsets[] = {0x25f0, 0x2628};
    const uint32_t expected = 0xd63f091f; // blraaz x8
    if (!OrigMTLCodeGenServiceBuildRequest) {
        MTLPatchLog("target adapter: symbol unavailable");
        OrigMTLCodeGenServiceBuildRequest = NULL;
        return;
    }

    uintptr_t target = StripPAC((const void *)MacWSMTLCodeGenServiceBuildRequest);
    uint32_t branches[sizeof(callOffsets) / sizeof(callOffsets[0])] = {0};
    for (size_t i = 0; i < sizeof(callOffsets) / sizeof(callOffsets[0]); i++) {
        uint32_t *callSite = (uint32_t *)((uintptr_t)mh + callOffsets[i]);
        intptr_t delta = (intptr_t)target - (intptr_t)callSite;
        if (*callSite != expected) {
            MTLPatchLog("target adapter: validation failed offset=%#lx site=%p insn=%#x",
                        (unsigned long)callOffsets[i], callSite, *callSite);
            OrigMTLCodeGenServiceBuildRequest = NULL;
            return;
        }
        if ((delta & 3) != 0 || delta < -(1LL << 27) ||
            delta >= (1LL << 27)) {
            MTLPatchLog("target adapter: wrapper out of BL range offset=%#lx site=%p target=%#lx delta=%#lx",
                        (unsigned long)callOffsets[i], callSite,
                        (unsigned long)target, (unsigned long)delta);
            OrigMTLCodeGenServiceBuildRequest = NULL;
            return;
        }
        branches[i] = 0x94000000u |
            ((uint32_t)((uint64_t)(delta >> 2) & 0x03ffffffu));
    }
    for (size_t i = 0; i < sizeof(callOffsets) / sizeof(callOffsets[0]); i++) {
        uint32_t *callSite = (uint32_t *)((uintptr_t)mh + callOffsets[i]);
        PatchInstruction(callSite, branches[i]);
        MTLPatchLog("target adapter installed offset=%#lx site=%p old=%#x new=%#x wrapper=%#lx orig=%p",
                    (unsigned long)callOffsets[i], callSite, expected,
                    *callSite, (unsigned long)target,
                    OrigMTLCodeGenServiceBuildRequest);
    }

    uint32_t *replyDataSite = (uint32_t *)((uintptr_t)mh + 0x2770);
    const uint32_t expectedReplyCall = 0x9400047c; // bl _xpc_data_create stub
    uintptr_t replyTarget = StripPAC((const void *)MacWSCompilerReplyDataCreate);
    intptr_t replyDelta = (intptr_t)replyTarget - (intptr_t)replyDataSite;
    if (*replyDataSite != expectedReplyCall || (replyDelta & 3) != 0 ||
        replyDelta < -(1LL << 27) || replyDelta >= (1LL << 27)) {
        MTLPatchLog("compiler reply observer validation failed site=%p insn=%#x target=%#lx delta=%#lx",
                    replyDataSite, *replyDataSite,
                    (unsigned long)replyTarget, (unsigned long)replyDelta);
        return;
    }
    uint32_t replyBranch = 0x94000000u |
        ((uint32_t)((uint64_t)(replyDelta >> 2) & 0x03ffffffu));
    PatchInstruction(replyDataSite, replyBranch);
    MTLPatchLog("compiler reply observer installed site=%p old=%#x new=%#x wrapper=%#lx",
                replyDataSite, expectedReplyCall, *replyDataSite,
                (unsigned long)replyTarget);
}

// Strip arm64e PAC bits from a pointer. dlsym/MSFindSymbol on arm64e
// returns PAC-signed pointers for code symbols; doing pointer arithmetic
// on them carries the PAC bits into the result and the dereference faults.
//
// iOS arm64e user space is a 47-bit VA (T0SZ=17), so the PAC tag begins at
// bit 47 — the low 47 bits (0..46) are the real address, bits 47..63 hold
// the tag. The PREVIOUS mask 0x0000FFFFFFFFFFFF kept the low *48* bits,
// which leaves bit 47 in place. PAC tags are per-process random, so bit 47
// is set ~50% of the time; when set, the "stripped" anchor lands at a bogus
// out-of-__TEXT address (e.g. 0x8001d1669514 instead of 0x1d1669514) and
// the bounds-checked BL scan in FindRenamerBLSite skips every probe →
// "no ADD+BL pair found" → renamer patch never applies → the
// agx.air.fract.v3f16.fast abort fires.
//
// RE-confirmed via /var/jb/var/mobile/mtl_compiler_patch.log (2026-06-20):
// EVERY anchor with bit47 set ("stripped=0x8001d1669514") FAILED the scan;
// EVERY bit47-clear anchor ("stripped=0x1ed3dd514") found the BL and NOPed
// OK — a 61/63 OK/FAIL coin-flip that exactly tracks bit 47. Masking the
// low 47 bits removes the tag for both cases (real user addresses never set
// bit 47, so this can't clobber a legitimate address).
static uintptr_t StripPAC(const void *p) {
    return (uintptr_t)p & 0x00007FFFFFFFFFFFull;
}

// Scan a window around (anchor + delta_hint) for the BL site preceded by
// `add x2, x2, #<imm12>` where the imm12 is the offset of the "agx."
// literal within its __cstring page. Two known imm12 values across the
// AGXCompilerCore variants we run against:
//   - iOS-16.3 DSC:        add x2, x2, #0x44e (encoding 0x91113842)
//   - macOS-13.4 chroot DSC: add x2, x2, #0xdf4 (encoding 0x9137d042)
// The MTLCompilerBypassOSCheck tweak runs in iOS-side MTLCompilerService
// only, so the iOS signature is what we actually need. But scanning for
// either makes the code robust if the DSC version shifts.
// Returns the BL site pointer or NULL if not found in the search window.
//
// `image_lo`/`image_hi` bound the scan to the AGXCompilerCore image —
// passing 0/0 lets the scan run unrestrained. We also wrap each
// dereference in a SIGBUS/SIGSEGV-tolerant sigsetjmp so an off-image
// probe just stops the scan instead of crashing the whole tweak.
#include <setjmp.h>
#include <signal.h>
static sigjmp_buf g_renamer_scan_jmp;
static volatile sig_atomic_t g_renamer_scan_in_probe = 0;
static void RenamerScanSignalHandler(int sig) {
    (void)sig;
    if (g_renamer_scan_in_probe) {
        siglongjmp(g_renamer_scan_jmp, 1);
    }
}
static uint32_t *FindRenamerBLSite(void *anchor_raw, intptr_t delta_hint,
                                   int window_bytes,
                                   uintptr_t image_lo, uintptr_t image_hi) {
    // `add x2, x2, #imm12` encoding with imm12 specific to each DSC variant.
    // iOS-16.3 sees the "agx." literal at __cstring offset 0x44e; macOS-13.4
    // chroot at 0xdf4. Match either so the patch is portable.
    const uint32_t SIG_ADD_X2_44E = 0x91113842u; // add x2, x2, #0x44e (iOS)
    const uint32_t SIG_ADD_X2_DF4 = 0x9137d042u; // add x2, x2, #0xdf4 (chroot)
    uintptr_t anchor = StripPAC(anchor_raw);
    uint32_t *base = (uint32_t *)(anchor + delta_hint);
    int max_words = window_bytes / 4;

    struct sigaction sa_old_segv, sa_old_bus, sa = {0};
    sa.sa_handler = RenamerScanSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, &sa_old_segv);
    sigaction(SIGBUS,  &sa, &sa_old_bus);

    uint32_t *found = NULL;
    for (int off = -max_words; off <= max_words; off++) {
        uint32_t *probe = base + off;
        if (image_hi && ((uintptr_t)probe < image_lo + 4 ||
                         (uintptr_t)probe >= image_hi)) continue;
        uint32_t prev_insn, cur_insn;
        if (sigsetjmp(g_renamer_scan_jmp, 1) != 0) continue;
        g_renamer_scan_in_probe = 1;
        prev_insn = probe[-1];
        cur_insn  = probe[0];
        g_renamer_scan_in_probe = 0;
        if ((prev_insn == SIG_ADD_X2_44E ||
             prev_insn == SIG_ADD_X2_DF4) &&
            ((cur_insn >> 26) & 0x3F) == 0x25) {
            found = probe;
            break;
        }
    }
    sigaction(SIGSEGV, &sa_old_segv, NULL);
    sigaction(SIGBUS,  &sa_old_bus,  NULL);
    return found;
}

// Walk dyld's image list to get the AGXCompilerCore binary's mapped
// __TEXT range. We use this to bound the scan so an off-end probe
// doesn't dereference unmapped memory.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
static void GetAGXCompilerCoreTextRange(uintptr_t *lo_out, uintptr_t *hi_out) {
    *lo_out = 0; *hi_out = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "AGXCompilerCore")) continue;
        const struct mach_header_64 *mh =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mh) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *lc =
            (const struct load_command *)((const char *)mh + sizeof(*mh));
        for (uint32_t j = 0; j < mh->ncmds; j++) {
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sc =
                    (const struct segment_command_64 *)lc;
                if (strncmp(sc->segname, "__TEXT", 16) == 0) {
                    *lo_out = (uintptr_t)sc->vmaddr + slide;
                    *hi_out = *lo_out + sc->vmsize;
                    return;
                }
            }
            lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
        }
    }
}

static void PatchAGXRenamerSkipAgxPrefix(void) {
    MTLPatchLog("renamer-patch: ENTER pid=%d", getpid());
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        MTLPatchLog("renamer-patch: dlopen FAILED: %s",
                    dlerror() ?: "(no dlerror)");
        return;
    }
    MTLPatchLog("renamer-patch: dlopen ok (h=%p)", h);
    MSImageRef img = MSGetImageByName(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore");
    if (!img) {
        MTLPatchLog("renamer-patch: MSGetImageByName returned NULL");
        return;
    }
    void *anchor = MSFindSymbol(img, "_AIRNTGetVersion");
    if (!anchor) {
        MTLPatchLog("renamer-patch: MSFindSymbol _AIRNTGetVersion NULL");
        return;
    }
    uintptr_t anchor_stripped = StripPAC(anchor);
    MTLPatchLog("renamer-patch: anchor _AIRNTGetVersion=%p (stripped=%#lx)",
                anchor, (long)anchor_stripped);

    uintptr_t image_lo = 0, image_hi = 0;
    GetAGXCompilerCoreTextRange(&image_lo, &image_hi);
    MTLPatchLog("renamer-patch: AGXCompilerCore __TEXT range %#lx-%#lx",
                (long)image_lo, (long)image_hi);

    // Known iOS-16.3 delta from prior RE. May be stale — the scan below
    // handles drift by walking +/-16KB around the hint for the
    // (ADD x2,x2,#0xdf4 ; BL) pair.
    intptr_t delta_hint = -0x1259a4;
    uint32_t *bl_site = FindRenamerBLSite(anchor, delta_hint,
                                          16 * 1024,
                                          image_lo, image_hi);
    if (!bl_site) {
        MTLPatchLog("renamer-patch: ADD+BL signature NOT found within "
                    "+/-16KB of anchor+delta_hint=%#lx — scanning whole "
                    "__text for fallback", (unsigned long)delta_hint);
        // Broader fallback: scan from the image base offset, bounded by
        // __TEXT range. AGXCompilerCore's __text is roughly 1.7MB.
        if (image_hi) {
            // window = entire __TEXT size, centred at anchor
            int win = (int)(image_hi - image_lo);
            bl_site = FindRenamerBLSite(anchor, 0, win,
                                        image_lo, image_hi);
        }
        if (!bl_site) {
            MTLPatchLog("renamer-patch: FAILED — no ADD+BL pair found "
                        "within AGXCompilerCore __TEXT");
            return;
        }
    }
    intptr_t actual_delta = (intptr_t)((uintptr_t)bl_site - anchor_stripped);
    uint32_t cur = bl_site[0];
    MTLPatchLog("renamer-patch: found BL site=%p actual_delta=%#lx insn=%#x",
                bl_site, (long)actual_delta, cur);
    PatchInstruction(bl_site, 0xd503201fu);  // NOP
    uint32_t after = bl_site[0];
    MTLPatchLog("renamer-patch: NOPed BL site=%p was=%#x now=%#x %s",
                bl_site, cur, after,
                after == 0xd503201fu ? "OK" : "FAIL");
}

static void PatchAGXVerifyLoweredIR(void) {
    void *h = dlopen(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore",
        RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        NSLog(@"#### MTLCompilerBypassOSCheck dlopen AGXCompilerCore: %s",
              dlerror());
        return;
    }
    MSImageRef img = MSGetImageByName(
        "/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore");
    if (!img) {
        NSLog(@"#### MTLCompilerBypassOSCheck AGXCompilerCore not in image table");
        return;
    }
    void *anchor = MSFindSymbol(img, "_AIRNTGetVersion");
    if (!anchor) {
        NSLog(@"#### MTLCompilerBypassOSCheck _AIRNTGetVersion not found");
        return;
    }
    // verifier = anchor + delta. Measured on iPad13,6 16.3.1 (20D67) DSC.
    intptr_t delta = -0x5fb78;
    uint32_t *verifier = (uint32_t *)((uintptr_t)anchor + delta);
    const uint32_t kPacibsp = 0xd503237fu;
    const uint32_t kRet     = 0xd65f03c0u;
    if (verifier[0] != kPacibsp) {
        NSLog(@"#### MTLCompilerBypassOSCheck verifier@%p first insn=%#x "
              "expected %#x — DSC version drift, NOT patching",
              verifier, verifier[0], kPacibsp);
        return;
    }
    PatchInstruction(verifier, kRet);
    NSLog(@"#### MTLCompilerBypassOSCheck verifyLoweredIR @%p patched "
          "pacibsp → ret (AGX shader verify now permissive)", verifier);
}

%ctor {
    InstallMetalCachePathAdapter();
    // NSLog(@"#### debugbydcmmc MTLCompilerBypassOSCheck start");
    dlopen("/System/Library/PrivateFrameworks/MTLCompiler.framework/MTLCompiler", RTLD_GLOBAL);
    MSImageRef image = MSGetImageByName("/System/Library/PrivateFrameworks/MTLCompiler.framework/MTLCompiler");
    if (image) {
    uint32_t *symbol = MSFindSymbol(image, "__ZN17MTLCompilerObject27readModuleFromBinaryRequestERK20ReadModuleParametersRN4llvm11LLVMContextEP15MTLFunctionTypePPvPmb");
    if (symbol) {
    MTLPatchLog("readModuleFromBinaryRequest symbol=%p stripped=%#lx",
                symbol, (unsigned long)StripPAC(symbol));

    // The OS check is the triplet:
    //   0xb94087e8  ldr w8, [sp, #0x84]
    //   0x71001d1f  cmp w8, #0x7              (iOS platform enum)
    //   0x540003a1  b.ne <error path: "Target OS is incompatible.">
    // The PREVIOUS implementation walked the function looking for the first
    // ldr-w8 and asserted on the next cmp, which was brittle: if MSFindSymbol
    // returned a slightly different address or the function's preamble was
    // shifted on a newer iOS DSC, the walk could either go off the end of
    // the dylib's __TEXT (SEGV) or land on a false match. Now we verify all
    // three instructions and cap the scan window so a miss is silent rather
    // than fatal.
    const uint32_t SIG_LDR  = 0xb94087e8u;
    const uint32_t SIG_CMP  = 0x71001d1fu;
    const uint32_t SIG_BNE  = 0x540003a1u;
    const int MAX_WALK_INSNS = 4096;  // bounds the scan to ~16KB of __text
    int hit = 0;
    for (int i = 0; i < MAX_WALK_INSNS; i++) {
        if (symbol[i]   == SIG_LDR &&
            symbol[i+1] == SIG_CMP &&
            symbol[i+2] == SIG_BNE) {
            PatchInstruction(&symbol[i + 2], 0xd503201f); // nop the b.ne
            MTLPatchLog("readModule OS check exact hit index=%d branch=%p "
                        "ldr=%#x cmp=%#x oldBranch=%#x newBranch=%#x",
                        i, &symbol[i + 2], symbol[i], symbol[i + 1],
                        SIG_BNE, symbol[i + 2]);
            hit = 1;
            break;
        }
    }
    if (!hit) {
        // Fallback: try the older partial-match where b.ne could be a
        // different conditional but cmp w8 #0x7 is still the marker.
        for (int i = 0; i < MAX_WALK_INSNS; i++) {
            if (symbol[i]   == SIG_LDR &&
                symbol[i+1] == SIG_CMP &&
                ((symbol[i+2] & 0xff00001fu) == 0x54000001u)) {
                PatchInstruction(&symbol[i + 2], 0xd503201f);
                MTLPatchLog("readModule OS check fallback hit index=%d "
                            "branch=%p ldr=%#x cmp=%#x newBranch=%#x",
                            i, &symbol[i + 2], symbol[i], symbol[i + 1],
                            symbol[i + 2]);
                hit = 1;
                break;
            }
        }
    }

    if (!hit) {
        MTLPatchLog("readModule OS check signature NOT found in 16KB");
    }

    } // if (symbol)
    } // if (image)

    InstallMacOSMetalTargetAdapter();

    // Originally tried: PatchAGXVerifyLoweredIR() — bypass the
    // AGCLLVMUserObject::verifyLoweredIR check that surfaces the
    // `agx.air.fract.v3f16.fast` unlowered-call error. That moved the
    // crash into libLLVM (NULL Function metadata at offset 0x30 in
    // codegen) — see commit message. Kept for reference only.
    (void)PatchAGXVerifyLoweredIR;
    // Actual fix: disable the rename inside AGCLLVMUserObject::
    // linkMetalRuntime that produces `agx.air.fract.v3f16.fast` from
    // an existing `air.fract.v3f16`. The dispatcher
    // AGCLLVMAirBuiltins::replaceBuiltins requires the function name
    // to start with "air." (it calls findPrefix(name, "air.", 4) and
    // bails if the prefix doesn't match), so the renamer's "agx."
    // prepend hides the function from the dispatcher and leaves it
    // unlowered. If we skip the prepend, the result is
    // `air.fract.v3f16.fast` — still starts with "air.", findPrefix
    // splits at the first '.' after the prefix so the dispatcher
    // gets out1="fract" and looks up buildFract, which reads the
    // actual operand type (half3) from the LLVM Value and emits the
    // valid `x - floor(x)` lowering. No more unlowered call → no
    // verifier complaint → no abort.
    //
    // Opt-in: set MTLCOMPILER_PATCH_RENAMER=1 in the LaunchAgent
    // environment to enable. Disabled by default until we can
    // confirm it doesn't regress WindowServer startup (current
    // observation: when enabled, WindowServer dies before reaching
    // pipeline build, suggesting the patched MTLCompilerService is
    // returning compiled binaries that fail differently — possible
    // ordering issue, possible findPrefix split mismatch we haven't
    // RE'd yet).
    // Opt-in via env (set MTLCOMPILER_PATCH_RENAMER=1 in MTLCompilerService's
    // launchd environment to enable). Verified-correct patch site by static RE
    // — anchor `_AIRNTGetVersion` minus delta `-0x1259a4` lands on `bl
    // std::string::insert(0, "agx.")` in
    // `AGCLLVMUserObject::linkMetalRuntime`. Empirically, however, enabling
    // the patch on this iOS-16.3 build did NOT prevent the
    // `agx.air.fract.v3f16.fast` abort — same payload still fires. Two
    // most likely explanations to investigate next:
    //   (a) Substrate's MTLCompilerService filter on this Dopamine install
    //       is loading the tweak too late (after AGCLLVMUserObject has
    //       already cached the renamed Function declarations from a prior
    //       MetalRuntime warm-up). lldb verification was inconclusive
    //       because the per-request MTLCompilerService spawn lifetime is
    //       too short to attach without altering timing.
    //   (b) the iOS-16.3 AGXCompilerCore has a SECOND `agx.` prepend
    //       path I haven't located yet. Only one `"agx."` literal xref
    //       exists in the iOS binary (chroot has 5, four of which are in
    //       raytracing accessors), and we patched the matching one, so
    //       this would have to be a Twine concatenation that doesn't
    //       reuse the standalone literal — feasible if the renamer
    //       constructs `Twine("agx.air.") + …` directly off the longer
    //       agx.air.indirect literal at iOS 0x199a891 (sliding 8 chars
    //       earlier into "agx.air." would give a usable prefix).
    // Always run the renamer patch — no env gate. XPC services don't
    // inherit env vars from the WS launchd plist and modifying the
    // service's own Info.plist would require re-signing the bundle.
    // The patch is signature-validated (only fires when both the ADD
    // x2,x2,#0xdf4 AND BL opcode match within the search window), so
    // an unknown DSC version safely no-ops instead of corrupting code.
    MTLPatchLog("%%ctor: OS-check patched; running renamer patch now");
    PatchAGXRenamerSkipAgxPrefix();
    if (access("/var/jb/var/mobile/macws_mtlcompiler_hold", F_OK) == 0) {
        MTLPatchLog("diagnostic hold: SIGSTOP before accepting compiler requests");
        raise(SIGSTOP);
    }
}
