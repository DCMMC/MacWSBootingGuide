@import Darwin;
@import CydiaSubstrate;
@import Foundation;
@import MachO;

#include <dlfcn.h>
#include <crt_externs.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <spawn.h>

// Valve's tier0 helper launcher has this exported ABI on Steam client build
// 1785799196 (arm64). RE-confirmed in libtier0_s.dylib at +0xd91c:
//
//   x0 command/argv, x1 flags, x2 cwd
//   bit 1: setpgrp, then setsid (the latter necessarily fails after the child
//          became a process-group leader, so the effective contract is a new
//          process group in the parent's existing session)
//   bit 2: shell command, bit 3: execv argv, bit 4: execvp argv
//
// Steam's webhelper call site in chromehtml.dylib at +0x71da0 passes 0x0a,
// so the child contract is argv + new session. The original implementation
// uses fork() first. On iPadOS 16.3 the child then crashes before exec inside
// Network.framework's nw_settings_child_has_forked atfork handler, jumping to
// the read-only xpc_dictionary_apply data page (runtime crash witness:
// steam_osx-2026-08-13-064756.ips).
//
// Reproduce the process contract atomically with posix_spawn. This avoids
// inheriting initialized Network/XPC state; it does not skip an atfork handler
// or claim that a failed child launch succeeded.
typedef int (*MacWSCreateSimpleProcessFunction)(
    void *, int, const char *);
static MacWSCreateSimpleProcessFunction gMacWSOriginalCreateSimpleProcess;
static int MacWSSteamCreateSimpleProcess(void *commandOrArguments, int flags,
                                         const char *workingDirectory);
static bool MacWSPathEndsWith(const char *path, const char *suffix);
static bool MacWSIsTopLevelSteamBrowser(void);
static void MacWSInstallSteamApplicationLaunchCompatibility(void);
extern kern_return_t bootstrap_check_in_new(
    mach_port_t bootstrapPort, const char *serviceName,
    mach_port_t *servicePort);
extern kern_return_t bootstrap_look_up_new(
    mach_port_t bootstrapPort, const char *serviceName,
    mach_port_t *servicePort);
extern void ModifyExecutableRegion(void *address, size_t size,
                                   void (^callback)(void));

static void MacWSRebindSteamProcessImport(const struct mach_header *header,
                                           intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) return;
    Dl_info imageInfo = {0};
    if (!dladdr(header, &imageInfo) || !imageInfo.dli_fname) return;
    if (strstr(imageInfo.dli_fname, "/libmachook") ||
        strstr(imageInfo.dli_fname, "/libtier0_s.dylib")) return;
    bool chromiumFramework = strstr(
        imageInfo.dli_fname,
        "/Chromium Embedded Framework.framework/") != NULL;

    const struct mach_header_64 *header64 =
        (const struct mach_header_64 *)header;
    const struct load_command *command =
        (const struct load_command *)(header64 + 1);
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symbols = NULL;
    const struct dysymtab_command *dynamicSymbols = NULL;
    for (uint32_t index = 0; index < header64->ncmds; index++) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if (!strcmp(segment->segname, SEG_LINKEDIT)) linkedit = segment;
        } else if (command->cmd == LC_SYMTAB) {
            symbols = (const struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dynamicSymbols = (const struct dysymtab_command *)command;
        }
        command = (const struct load_command *)
            ((const uint8_t *)command + command->cmdsize);
    }
    if (!linkedit || !symbols || !dynamicSymbols) return;

    uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr -
        linkedit->fileoff;
    const struct nlist_64 *symbolTable =
        (const struct nlist_64 *)(linkeditBase + symbols->symoff);
    const char *stringTable =
        (const char *)(linkeditBase + symbols->stroff);
    const uint32_t *indirectTable =
        (const uint32_t *)(linkeditBase + dynamicSymbols->indirectsymoff);

    command = (const struct load_command *)(header64 + 1);
    for (uint32_t commandIndex = 0;
         commandIndex < header64->ncmds; commandIndex++) {
        if (command->cmd != LC_SEGMENT_64) {
            command = (const struct load_command *)
                ((const uint8_t *)command + command->cmdsize);
            continue;
        }
        const struct segment_command_64 *segment =
            (const struct segment_command_64 *)command;
        const struct section_64 *section =
            (const struct section_64 *)(segment + 1);
        for (uint32_t sectionIndex = 0;
             sectionIndex < segment->nsects; sectionIndex++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS &&
                type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            uintptr_t *pointers = (uintptr_t *)
                ((uintptr_t)slide + section->addr);
            size_t count = (size_t)(section->size / sizeof(uintptr_t));
            for (size_t pointerIndex = 0;
                 pointerIndex < count; pointerIndex++) {
                uint32_t indirectIndex = section->reserved1 + pointerIndex;
                if (indirectIndex >= dynamicSymbols->nindirectsyms) break;
                uint32_t symbolIndex =
                    indirectTable[indirectIndex];
                if (symbolIndex == INDIRECT_SYMBOL_ABS ||
                    symbolIndex == INDIRECT_SYMBOL_LOCAL ||
                    symbolIndex == (INDIRECT_SYMBOL_LOCAL |
                                    INDIRECT_SYMBOL_ABS) ||
                    symbolIndex >= symbols->nsyms) continue;
                const char *name = stringTable +
                    symbolTable[symbolIndex].n_un.n_strx;
                if (!name) continue;
                uintptr_t replacement = 0;
                bool directLazyWrite = false;
                if (!strcmp(name, "_CreateSimpleProcess")) {
                    // Never publish the Valve adapter until its fallback
                    // target is known. dyld can notify us about steamui before
                    // libtier0; any unsupported call in that interval must
                    // retain Valve's implementation.
                    if (!gMacWSOriginalCreateSimpleProcess) continue;
                    replacement = (uintptr_t)MacWSSteamCreateSimpleProcess;
                } else if (chromiumFramework &&
                           type == S_LAZY_SYMBOL_POINTERS &&
                           !strcmp(name, "_bootstrap_check_in")) {
                    replacement = (uintptr_t)bootstrap_check_in_new;
                    directLazyWrite = true;
                } else if (chromiumFramework &&
                           type == S_LAZY_SYMBOL_POINTERS &&
                           !strcmp(name, "_bootstrap_look_up")) {
                    replacement = (uintptr_t)bootstrap_look_up_new;
                    directLazyWrite = true;
                } else {
                    continue;
                }
                uintptr_t previous = __atomic_load_n(
                    &pointers[pointerIndex], __ATOMIC_ACQUIRE);
                if (directLazyWrite) {
                    // __DATA,__la_symbol_ptr is writable in this exact CEF
                    // image. A direct atomic store is the fishhook contract:
                    // the existing stub now branches to our wrapper and never
                    // enters dyld_stub_binder, so no later lazy bind can
                    // replace it. MSHookMemory is for executable/const pages
                    // and did not provide a verifiable data-slot write here.
                    __atomic_store_n(&pointers[pointerIndex], replacement,
                                     __ATOMIC_RELEASE);
                } else {
                    // This slot may live in __DATA_CONST. Do not use
                    // MSHookMemory here: runtime-confirmed in Steam Helper
                    // PID 90074 that ElleKit's stopAllThreads suspended all
                    // 32 peer threads while rebinding steamclient.dylib and
                    // returned without balancing them. The project's writer
                    // preserves the actual region permissions and tracks each
                    // successful peer suspension through its matching resume.
                    ModifyExecutableRegion(&pointers[pointerIndex],
                                           sizeof(replacement), ^{
                        __atomic_store_n(&pointers[pointerIndex], replacement,
                                         __ATOMIC_RELEASE);
                    });
                }
                uintptr_t readback = __atomic_load_n(
                    &pointers[pointerIndex], __ATOMIC_ACQUIRE);
                if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
                    fprintf(stderr,
                            "[MacWSSteamProcess] rebound import image=%s "
                            "symbol=%s slot=%p previous=%p replacement=%p "
                            "readback=%p%s\n",
                            imageInfo.dli_fname, name,
                            &pointers[pointerIndex], (void *)previous,
                            (void *)replacement, (void *)readback,
                            readback == replacement ? "" : " WRITE-FAILED");
                    fflush(stderr);
                }
            }
        }
        command = (const struct load_command *)
            ((const uint8_t *)command + command->cmdsize);
    }
}

static bool MacWSIsSteamProcess(void) {
    const char *program = getprogname();
    if (program && (!strcmp(program, "steam_osx") ||
                    !strcmp(program, "Steam Helper"))) return true;
    char executable[PATH_MAX] = {0};
    extern int proc_pidpath(int, void *, uint32_t);
    return proc_pidpath(getpid(), executable, sizeof(executable)) > 0 &&
        strstr(executable, "/Library/Application Support/Steam/") != NULL;
}

static bool MacWSIsTopLevelSteamBrowser(void) {
    const char *program = getprogname();
    if (!program || strcmp(program, "Steam Helper") != 0) return false;
    char ***argumentsPointer = _NSGetArgv();
    char **arguments = argumentsPointer ? *argumentsPointer : NULL;
    for (size_t index = 1; arguments && arguments[index]; index++) {
        if (!strncmp(arguments[index], "--type=", 7)) return false;
    }
    return true;
}

// Steam's native macOS game path deliberately uses NSWorkspace instead of
// Valve's _CreateSimpleProcess adapter. Runtime-confirmed with client
// 1785799196: Stray reaches CreatingProcess with its .app URL, while no
// _CreateSimpleProcess entry is recorded.
//
// There are two incompatible integrity owners on iPadOS. Steam must keep the
// depot copy byte-for-byte vendor signed or its content verifier reports a
// corrupt file signature. The iPadOS exec policy rejects that same macOS
// Developer-ID main executable even after its original CDHash is placed in the
// jailbreak trustcache. Runtime oslog witness for the untouched Stray binary:
//
//   System Policy: bash(...) deny(1) process-exec* .../Stray-Mac-Shipping
//   process-exec denied while updating label
//   killing com.annapurnainteractive.Stray ... failed to apply exec policy
//
// The root-layer compatibility is a separately prepared APFS-cloned runtime
// app below steamapps/macws-runtime. Its code files carry the MacWS signing
// profile while its large resources share storage with the depot copy. Steam
// continues to verify only steamapps/common. Preserve NSWorkspace as launch
// owner: first let it attempt the exact vendor bundle, then retry the prepared
// runtime bundle with the same options/arguments/environment. posix_spawn is a
// final fallback only if both stock NSWorkspace attempts fail.
typedef id (*MacWSNSWorkspaceLaunchFunction)(
    id, SEL, NSURL *, NSUInteger, NSDictionary *, NSError **);
static MacWSNSWorkspaceLaunchFunction
    gMacWSOriginalNSWorkspaceLaunchApplication;
static MacWSNSWorkspaceLaunchFunction gMacWSOriginalNSWorkspaceOpenURL;
typedef id (*MacWSNSWorkspaceOpenURLsFunction)(
    id, SEL, NSArray *, NSURL *, NSUInteger, NSDictionary *, NSError **);
static MacWSNSWorkspaceOpenURLsFunction gMacWSOriginalNSWorkspaceOpenURLs;

static NSURL *MacWSSteamRuntimeApplicationURL(NSString *applicationPath) {
    static NSString *const steamAppsPrefix =
        @"/Users/root/Library/Application Support/Steam/steamapps/common/";
    static NSString *const runtimePrefix =
        @"/Users/root/Library/Application Support/Steam/steamapps/macws-runtime/";
    if (![applicationPath hasPrefix:steamAppsPrefix] ||
        ![applicationPath hasSuffix:@".app"]) return nil;

    NSString *relative = [applicationPath substringFromIndex:
        steamAppsPrefix.length];
    if (!relative.length || [relative hasPrefix:@"/"] ||
        [[relative pathComponents] containsObject:@".."]) return nil;
    NSString *runtimePath = [runtimePrefix stringByAppendingPathComponent:
        relative];
    NSString *readyMarker = [[runtimePath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@".macws-shadow-ready"];
    NSString *infoPath = [runtimePath stringByAppendingPathComponent:
        @"Contents/Info.plist"];
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:readyMarker] ||
        ![files fileExistsAtPath:infoPath]) return nil;

    // Stray's UE4 PhysX loader asks for libAPEXFramework.dylib, while the
    // vendor bundle spells the file libApexFramework.dylib.  That is the same
    // file on a stock case-insensitive macOS APFS volume, but not on the
    // case-sensitive chroot rootfs.  Keep Steam's verified depot untouched and
    // reproduce the normal macOS lookup contract in the writable runtime
    // shadow with a relative alias.
    NSString *physXDirectory = [runtimePath stringByAppendingPathComponent:
        @"Contents/UE4/Engine/Binaries/ThirdParty/PhysX3/Mac"];
    NSString *physXTarget = [physXDirectory stringByAppendingPathComponent:
        @"libApexFramework.dylib"];
    NSString *physXAlias = [physXDirectory stringByAppendingPathComponent:
        @"libAPEXFramework.dylib"];
    if ([files fileExistsAtPath:physXTarget] &&
        ![files fileExistsAtPath:physXAlias]) {
        NSError *aliasError = nil;
        [files createSymbolicLinkAtPath:physXAlias
                   withDestinationPath:@"libApexFramework.dylib"
                                  error:&aliasError];
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
            fprintf(stderr,
                    "[MacWSSteamProcess] PhysX case alias path=%s result=%s "
                    "error=%s\n",
                    physXAlias.UTF8String ?: "(null)",
                    [files fileExistsAtPath:physXAlias] ? "ready" : "failed",
                    aliasError.localizedDescription.UTF8String ?: "(none)");
            fflush(stderr);
        }
    }
    return [NSURL fileURLWithPath:runtimePath isDirectory:YES];
}

static NSString *MacWSInsertLibraryForSteamExecutable(
        NSString *executablePath) {
    // Steam's LaunchServices configuration does not retain dyld's insertion
    // variable.  Runtime LLDB on Stray PID 82012 showed the child stopped in
    // libSystem_initializer -> os_variant_has_internal_diagnostics while
    // `image list libmachook*.dylib` returned no modules.  Select the same
    // thin runtime slice as launchdchrootexec from the executable's actual
    // Mach-O subtype.  A universal Steam title executes its arm64 slice on
    // this device, so the non-thin/default result is arm64 rather than arm64e.
    NSString *insert = @"/usr/local/lib/libmachook_arm64.dylib";
    int descriptor = open(executablePath.fileSystemRepresentation, O_RDONLY);
    if (descriptor < 0) return insert;
    struct mach_header_64 header = {};
    ssize_t readCount = pread(descriptor, &header, sizeof(header), 0);
    close(descriptor);
    if (readCount == sizeof(header) && header.magic == MH_MAGIC_64 &&
        header.cputype == CPU_TYPE_ARM64 &&
        (header.cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E) {
        insert = @"/usr/local/lib/libmachook.dylib";
    }
    return insert;
}

static char **MacWSCopyEnvironmentForWorkspaceConfiguration(
        NSDictionary *configuration, NSString *executablePath) {
    NSDictionary *configured = [configuration objectForKey:
        @"NSWorkspaceLaunchConfigurationEnvironment"];
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:
        [[NSProcessInfo processInfo] environment]];
    if ([configured isKindOfClass:[NSDictionary class]])
        [merged addEntriesFromDictionary:configured];
    if (executablePath.length) {
        merged[@"DYLD_INSERT_LIBRARIES"] =
            MacWSInsertLibraryForSteamExecutable(executablePath);
        // Steam's own CEF stays on the bounded CPU download profile, but a
        // launched macOS game must receive the production native-AGX contract.
        // Do this in the child environment so enabling a game never revives
        // Steam Helper's historical GPU/SwiftShader memory growth.
        if ([executablePath containsString:@"/steamapps/macws-runtime/"]) {
            [merged removeObjectForKey:@"MACWS_STEAM_CPU_RENDERING"];
            merged[@"MACWS_AGX_NATIVE"] = @"1";
            merged[@"MACWS_AGX_REGISTER_CLASSES"] = @"1";
            merged[@"MACWS_PIN_FALLBACK"] = @"1";
            // Stray's macOS 13 AGX command records have producer-version ABI
            // fields that differ from iOS 16's native consumer.  Keep the
            // exact, anchor-validated adapters game-scoped; Steam itself and
            // unrelated games must not inherit them.  This also makes the
            // verified NSWorkspace launch use the same contract as the
            // direct diagnostic runner instead of depending on the launcher's
            // ambient environment.
            if ([executablePath.lastPathComponent
                    isEqualToString:@"Stray-Mac-Shipping"])
                merged[@"MACWS_STRAY_AGX_COMPAT"] = @"1";
        }
        // Reuse the existing bounded termination recorder only while the
        // Steam launch adapter's explicit diagnostic mode is enabled.  This
        // is removed with MACWS_STEAM_PROCESS_DIAGNOSTICS in production.
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS"))
            merged[@"MACWS_STEAM_EXIT_DIAGNOSTICS"] = @"1";
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS"))
            merged[@"MACWS_STEAM_UE4_DIAGNOSTICS"] = @"1";
    }
    // launchdchrootexec normally supplies this data invariant to descendants.
    // Keep it explicit when Steam creates a fresh environment dictionary.
    if (![merged[@"MACWS_CHROOT_HOST_ROOT"] isKindOfClass:[NSString class]])
        merged[@"MACWS_CHROOT_HOST_ROOT"] = @"/private/var/mnt/rootfs";

    char **environment = calloc(merged.count + 1, sizeof(*environment));
    if (!environment) return NULL;
    __block size_t output = 0;
    __block bool valid = true;
    [merged enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]] ||
            ![value isKindOfClass:[NSString class]]) {
            valid = false;
            *stop = YES;
            return;
        }
        const char *keyBytes = [(NSString *)key UTF8String];
        const char *valueBytes = [(NSString *)value UTF8String];
        if (!keyBytes || !valueBytes ||
            asprintf(&environment[output], "%s=%s", keyBytes, valueBytes) < 0) {
            valid = false;
            *stop = YES;
            return;
        }
        output++;
    }];
    if (valid) return environment;
    for (size_t index = 0; index < output; index++) free(environment[index]);
    free(environment);
    return NULL;
}

static void MacWSFreeCStringVector(char **vector) {
    if (!vector) return;
    for (size_t index = 0; vector[index]; index++) free(vector[index]);
    free(vector);
}

static id MacWSSteamLaunchApplicationAtURL(
        id workspace, SEL selector, NSURL *applicationURL, NSUInteger options,
        NSDictionary *configuration, NSError **error) {
    id launched = gMacWSOriginalNSWorkspaceLaunchApplication
        ? gMacWSOriginalNSWorkspaceLaunchApplication(
            workspace, selector, applicationURL, options, configuration, error)
        : nil;
    NSError *originalError = error ? *error : nil;
    NSString *applicationPath = [applicationURL path];
    bool diagnostics = getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS") != NULL;
    if (diagnostics) {
        NSDictionary *configuredEnvironment = [configuration objectForKey:
            @"NSWorkspaceLaunchConfigurationEnvironment"];
        NSArray *configuredArguments = [configuration objectForKey:
            @"NSWorkspaceLaunchConfigurationArguments"];
        fprintf(stderr,
                "[MacWSSteamProcess] NSWorkspace launch path=%s options=%#lx "
                "result=%p error-domain=%s error-code=%ld argc=%lu envc=%lu\n",
                applicationPath.UTF8String ?: "(null)",
                (unsigned long)options, launched,
                originalError.domain.UTF8String ?: "(none)",
                (long)originalError.code,
                (unsigned long)([configuredArguments isKindOfClass:
                    [NSArray class]] ? configuredArguments.count : 0),
                (unsigned long)([configuredEnvironment isKindOfClass:
                    [NSDictionary class]] ? configuredEnvironment.count : 0));
        if ([configuredArguments isKindOfClass:[NSArray class]]) {
            for (NSUInteger index = 0; index < configuredArguments.count;
                 index++) {
                NSString *argument = configuredArguments[index];
                fprintf(stderr,
                        "[MacWSSteamProcess] workspace-argv[%lu]=%s\n",
                        (unsigned long)index,
                        [argument isKindOfClass:[NSString class]]
                            ? argument.UTF8String : "(non-string)");
            }
        }
        fflush(stderr);
    }
    static NSString *const steamAppsPrefix =
        @"/Users/root/Library/Application Support/Steam/steamapps/common/";
    if (launched || !getenv("MACWS_STEAM_APP_LAUNCH_COMPAT") ||
        ![applicationPath hasPrefix:steamAppsPrefix] ||
        ![applicationPath hasSuffix:@".app"]) {
        return launched;
    }

    // Steam has already verified the depot path before it reaches this call.
    // If the stock NSWorkspace launch failed, give the same LaunchServices
    // owner a separately signed runtime bundle. This retains app registration,
    // activation and Steam's launch environment instead of fabricating a
    // successful return around a failed source-bundle launch.
    NSURL *runtimeApplicationURL = MacWSSteamRuntimeApplicationURL(
        applicationPath);
    if (runtimeApplicationURL &&
        gMacWSOriginalNSWorkspaceLaunchApplication) {
        NSError *runtimeError = nil;
        id runtimeApplication =
            gMacWSOriginalNSWorkspaceLaunchApplication(
                workspace, selector, runtimeApplicationURL, options,
                configuration, &runtimeError);
        fprintf(stderr,
                "[MacWSSteamProcess] NSWorkspace runtime launch source=%s "
                "runtime=%s result=%p error-domain=%s error-code=%ld\n",
                applicationPath.UTF8String ?: "(null)",
                runtimeApplicationURL.path.UTF8String ?: "(null)",
                runtimeApplication,
                runtimeError.domain.UTF8String ?: "(none)",
                (long)runtimeError.code);
        fflush(stderr);
        if (runtimeApplication) {
            if (error) *error = nil;
            return runtimeApplication;
        }
        applicationURL = runtimeApplicationURL;
    }

    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault,
                                        (__bridge CFURLRef)applicationURL);
    CFURLRef executableURL = bundle ? CFBundleCopyExecutableURL(bundle) : NULL;
    NSString *executablePath = executableURL
        ? [(__bridge NSURL *)executableURL path] : nil;
    NSArray *configuredArguments = [configuration objectForKey:
        @"NSWorkspaceLaunchConfigurationArguments"];
    if (![configuredArguments isKindOfClass:[NSArray class]])
        configuredArguments = @[];
    // UE4 shipping builds normally keep their early boot log out of stderr.
    // During the bounded launch diagnostic, request the engine's own log and
    // preserve it in the chroot tmp directory.  These arguments are never
    // present when MACWS_STEAM_PROCESS_DIAGNOSTICS is disabled.
    NSArray *diagnosticArguments = diagnostics ? @[
        @"-log",
        @"-stdout",
        @"-FullStdOutLogOutput",
        @"-abslog=/tmp/MacWS-Stray.log"
    ] : @[];
    char **arguments = executablePath
        ? calloc(configuredArguments.count + diagnosticArguments.count + 2,
                 sizeof(*arguments)) : NULL;
    char **environment = MacWSCopyEnvironmentForWorkspaceConfiguration(
        configuration, executablePath);
    bool valid = arguments && environment;
    if (valid) arguments[0] = strdup(executablePath.UTF8String);
    for (NSUInteger index = 0; valid && index < configuredArguments.count;
         index++) {
        NSString *argument = configuredArguments[index];
        if (![argument isKindOfClass:[NSString class]] ||
            !(arguments[index + 1] = strdup(argument.UTF8String))) {
            valid = false;
        }
    }
    for (NSUInteger index = 0; valid && index < diagnosticArguments.count;
         index++) {
        NSString *argument = diagnosticArguments[index];
        NSUInteger output = configuredArguments.count + index + 1;
        if (!(arguments[output] = strdup(argument.UTF8String))) valid = false;
    }

    posix_spawn_file_actions_t actions;
    bool actionsReady = false;
    int spawnError = valid ? posix_spawn_file_actions_init(&actions) : EINVAL;
    if (spawnError == 0) {
        actionsReady = true;
        typedef int (*MacWSAddChdirFunction)(
            posix_spawn_file_actions_t *, const char *);
        MacWSAddChdirFunction addChdir = (MacWSAddChdirFunction)dlsym(
            RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
        NSString *workingDirectory =
            [executablePath stringByDeletingLastPathComponent];
        if (addChdir && workingDirectory.length)
            spawnError = addChdir(&actions, workingDirectory.UTF8String);
    }
    pid_t child = 0;
    if (spawnError == 0) {
        spawnError = posix_spawn(&child, executablePath.UTF8String,
                                 &actions, NULL, arguments, environment);
    }
    if (actionsReady) posix_spawn_file_actions_destroy(&actions);
    MacWSFreeCStringVector(arguments);
    MacWSFreeCStringVector(environment);
    if (executableURL) CFRelease(executableURL);
    if (bundle) CFRelease(bundle);

    id runningApplication = nil;
    if (spawnError == 0) {
        Class runningApplicationClass = NSClassFromString(@"NSRunningApplication");
        SEL runningSelector = NSSelectorFromString(
            @"runningApplicationWithProcessIdentifier:");
        for (unsigned int attempt = 0;
             attempt < 200 && !runningApplication; attempt++) {
            if ([runningApplicationClass respondsToSelector:runningSelector]) {
                runningApplication = ((id (*)(id, SEL, pid_t))objc_msgSend)(
                    runningApplicationClass, runningSelector, child);
            }
            if (!runningApplication) usleep(10000);
        }
        if (error) *error = nil;
    }
    fprintf(stderr,
            "[MacWSSteamProcess] NSWorkspace fallback executable=%s "
            "insert=%s spawn-error=%d pid=%d running-app=%p "
            "original-error=%ld\n",
            executablePath.UTF8String ?: "(null)",
            MacWSInsertLibraryForSteamExecutable(executablePath).UTF8String,
            spawnError, child, runningApplication,
            (long)originalError.code);
    fflush(stderr);
    return runningApplication;
}

static id MacWSSteamOpenURL(
        id workspace, SEL selector, NSURL *url, NSUInteger options,
        NSDictionary *configuration, NSError **error) {
    id launched = gMacWSOriginalNSWorkspaceOpenURL
        ? gMacWSOriginalNSWorkspaceOpenURL(
            workspace, selector, url, options, configuration, error) : nil;
    if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
        NSError *launchError = error ? *error : nil;
        fprintf(stderr,
                "[MacWSSteamProcess] NSWorkspace openURL path=%s "
                "options=%#lx result=%p error-domain=%s error-code=%ld\n",
                url.path.UTF8String ?: "(null)", (unsigned long)options,
                launched, launchError.domain.UTF8String ?: "(none)",
                (long)launchError.code);
        fflush(stderr);
    }
    if (launched || ![url.path hasSuffix:@".app"]) return launched;
    return MacWSSteamLaunchApplicationAtURL(
        workspace,
        NSSelectorFromString(
            @"launchApplicationAtURL:options:configuration:error:"),
        url, options, configuration, error);
}

static id MacWSSteamOpenURLs(
        id workspace, SEL selector, NSArray *urls, NSURL *applicationURL,
        NSUInteger options, NSDictionary *configuration, NSError **error) {
    id launched = gMacWSOriginalNSWorkspaceOpenURLs
        ? gMacWSOriginalNSWorkspaceOpenURLs(
            workspace, selector, urls, applicationURL, options,
            configuration, error) : nil;
    if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
        NSError *launchError = error ? *error : nil;
        fprintf(stderr,
                "[MacWSSteamProcess] NSWorkspace openURLs app=%s items=%lu "
                "options=%#lx result=%p error-domain=%s error-code=%ld\n",
                applicationURL.path.UTF8String ?: "(null)",
                (unsigned long)([urls isKindOfClass:[NSArray class]]
                    ? urls.count : 0),
                (unsigned long)options, launched,
                launchError.domain.UTF8String ?: "(none)",
                (long)launchError.code);
        fflush(stderr);
    }
    if (launched || ![applicationURL.path hasSuffix:@".app"])
        return launched;
    return MacWSSteamLaunchApplicationAtURL(
        workspace,
        NSSelectorFromString(
            @"launchApplicationAtURL:options:configuration:error:"),
        applicationURL, options, configuration, error);
}

static void MacWSInstallSteamApplicationLaunchCompatibility(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class workspaceClass = NSClassFromString(@"NSWorkspace");
        SEL sharedSelector = NSSelectorFromString(@"sharedWorkspace");
        id sharedWorkspace = [workspaceClass respondsToSelector:sharedSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass, sharedSelector)
            : nil;
        Class implementationClass = sharedWorkspace
            ? object_getClass(sharedWorkspace) : workspaceClass;
        SEL selector = NSSelectorFromString(
            @"launchApplicationAtURL:options:configuration:error:");
        Method method = implementationClass
            ? class_getInstanceMethod(implementationClass, selector) : NULL;
        if (!method) return;
        gMacWSOriginalNSWorkspaceLaunchApplication =
            (MacWSNSWorkspaceLaunchFunction)method_getImplementation(method);
        method_setImplementation(method,
                                 (IMP)MacWSSteamLaunchApplicationAtURL);
        SEL openURLSelector = NSSelectorFromString(
            @"openURL:options:configuration:error:");
        Method openURLMethod = class_getInstanceMethod(
            implementationClass, openURLSelector);
        if (openURLMethod) {
            gMacWSOriginalNSWorkspaceOpenURL =
                (MacWSNSWorkspaceLaunchFunction)method_getImplementation(
                    openURLMethod);
            method_setImplementation(openURLMethod, (IMP)MacWSSteamOpenURL);
        }
        SEL openURLsSelector = NSSelectorFromString(
            @"openURLs:withApplicationAtURL:options:configuration:error:");
        Method openURLsMethod = class_getInstanceMethod(
            implementationClass, openURLsSelector);
        if (openURLsMethod) {
            gMacWSOriginalNSWorkspaceOpenURLs =
                (MacWSNSWorkspaceOpenURLsFunction)method_getImplementation(
                    openURLsMethod);
            method_setImplementation(openURLsMethod, (IMP)MacWSSteamOpenURLs);
        }
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
            fprintf(stderr,
                    "[MacWSSteamProcess] NSWorkspace launch compatibility "
                    "installed class=%s launch=%p openURL=%p openURLs=%p\n",
                    implementationClass ? class_getName(implementationClass)
                        : "(null)",
                    gMacWSOriginalNSWorkspaceLaunchApplication,
                    gMacWSOriginalNSWorkspaceOpenURL,
                    gMacWSOriginalNSWorkspaceOpenURLs);
            fflush(stderr);
        }
    });
}

// AppKit's first finishLaunching pass asks HIServices for the lazily linked
// AccessibilityBaseImplementations image.  Steam CEF has already created and
// retired startup workers by that point.  On the iPadOS 16 kernel the macOS
// dyld recursive API lock can retain a Mach-thread owner name that is no
// longer valid: runtime-confirmed in Steam Helper 1785799196 with dlopen_from
// waiting on owner 0x10c02 while mach_port_type(task, 0x10c02) returned
// KERN_INVALID_NAME (0xf).
//
// Resolve the same HIServices soft-link accessor while the top-level browser
// is still in its single-threaded image-initializer phase.  The accessor does
// the stock dlopen and returns the stock implementation library; no
// Accessibility result or lock operation is bypassed.  Later AppKit
// registration consumes HIServices' initialized once-state and therefore
// does not begin its first lazy load after worker retirement.
static void MacWSPrepareSteamAccessibilityRuntime(void) {
    if (!MacWSIsTopLevelSteamBrowser()) return;
    typedef void *(*MacWSAccessibilityLibraryFunction)(void *);
    static const char *const paths[] = {
        "/System/Library/Frameworks/ApplicationServices.framework/"
        "Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices",
        "/System/Library/Frameworks/ApplicationServices.framework/"
        "Frameworks/HIServices.framework/HIServices",
        NULL,
    };
    MSImageRef image = NULL;
    for (size_t index = 0; paths[index] && !image; index++) {
        image = MSGetImageByName(paths[index]);
        if (!image && dlopen(paths[index], RTLD_LAZY | RTLD_LOCAL))
            image = MSGetImageByName(paths[index]);
    }

    // This generated HIServices soft-link accessor is deliberately private,
    // so dlsym cannot resolve it even after dlopen. RE-confirmed in the exact
    // macOS 13.4 DSC (UUID 7D9FAA84-5C6B-3EF4-9379-FABA64346673):
    // _libAccessibilityBaseImplementationsLibraryCore is at unslid
    // 0x185c79564 and performs the stock _sl_dlopen sequence. Resolve the
    // private symbol through Substrate's Mach-O image lookup instead.
    MacWSAccessibilityLibraryFunction library = image ?
        (MacWSAccessibilityLibraryFunction)MSFindSymbol(
            image, "_libAccessibilityBaseImplementationsLibraryCore") : NULL;
    if (!library) return;
    // RE-confirmed call sites in _AXUIElementRegisterServerWithRunLoop at
    // 0x185c535a8 and +0xf4 explicitly pass x0 = NULL to this accessor.
    void *handle = library(NULL);
    if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
        fprintf(stderr,
                "[MacWSSteamProcess] Accessibility implementation "
                "preloaded=%p\n", handle);
        fflush(stderr);
    }
}

// Valve's bit-2 call sites build a sequence of individually single-quoted
// arguments (runtime example: '.../steamsysinfo' '-steamid' '0' ...). Parse
// only that unambiguous form so it can be spawned atomically without a second
// shell exec. Any metacharacter, unquoted token or embedded quote rejects the
// parse and retains the native /bin/sh contract below.
static char **MacWSParseValveQuotedArguments(const char *command) {
    if (!command) return NULL;
    size_t count = 0;
    size_t capacity = 8;
    char **arguments = calloc(capacity, sizeof(*arguments));
    if (!arguments) return NULL;
    const char *cursor = command;
    while (*cursor) {
        while (*cursor == ' ' || *cursor == '\t') cursor++;
        if (!*cursor) break;
        if (*cursor++ != '\'') goto invalid;
        const char *start = cursor;
        while (*cursor && *cursor != '\'') cursor++;
        if (*cursor != '\'') goto invalid;
        size_t length = (size_t)(cursor - start);
        char *argument = strndup(start, length);
        if (!argument) goto invalid;
        cursor++;
        if (*cursor && *cursor != ' ' && *cursor != '\t') {
            free(argument);
            goto invalid;
        }
        if (count + 2 > capacity) {
            capacity *= 2;
            char **grown = realloc(arguments,
                                   capacity * sizeof(*arguments));
            if (!grown) {
                free(argument);
                goto invalid;
            }
            arguments = grown;
        }
        arguments[count++] = argument;
        arguments[count] = NULL;
    }
    if (count > 0 && arguments[0][0] == '/') return arguments;
invalid:
    for (size_t index = 0; index < count; index++) free(arguments[index]);
    free(arguments);
    return NULL;
}

static void MacWSFreeParsedArguments(char **arguments) {
    if (!arguments) return;
    for (size_t index = 0; arguments[index]; index++) free(arguments[index]);
    free(arguments);
}

static bool MacWSPathEndsWith(const char *path, const char *suffix) {
    if (!path || !suffix) return false;
    size_t pathLength = strlen(path);
    size_t suffixLength = strlen(suffix);
    return pathLength >= suffixLength &&
        !strcmp(path + pathLength - suffixLength, suffix);
}

// Steam's browser process runs under the same explicitly unsandboxed MacWS
// compatibility profile as its parent. Chromium 126 nevertheless attempts to
// construct the macOS Seatbelt parameter table and terminates at
// sandbox_parameters_mac.mm:69 when iPadOS cannot provide that macOS process
// metadata (runtime log: errno=EIO). Select Chromium's supported no-sandbox
// launch mode at the parent call site, before initialization; this keeps its
// internal invariants intact and matches the kernel policy already attached to
// the process. Restrict the switch to Valve's exact browser helper.
static bool MacWSSteamArgumentPresent(char *const *arguments,
                                      const char *expected) {
    for (size_t index = 0; arguments && arguments[index]; index++) {
        if (!strcmp(arguments[index], expected)) return true;
    }
    return false;
}

static bool MacWSSteamArgumentsHaveProcessType(char *const *arguments) {
    for (size_t index = 0; arguments && arguments[index]; index++) {
        if (!strncmp(arguments[index], "--type=", 7)) return true;
    }
    return false;
}

static char **MacWSArgumentsByAddingSteamBrowserPolicy(
    const char *executable, char *const *arguments) {
    static const char helperSuffix[] =
        "/Steam Helper.app/Contents/MacOS/Steam Helper";
    if (!MacWSPathEndsWith(executable, helperSuffix) || !arguments) return NULL;
    size_t count = 0;
    while (arguments[count]) count++;

    // Steam's outer -cef-disable-gpu switch enables Chromium's software
    // compositor but still allows the GPU helper to instantiate SwiftShader.
    // The historical Jetsam witness attributed 600180 resident 16-KiB pages
    // (9.16 GiB) to that exact gpu-process role. In the explicit download/UI
    // profile, keep software page compositing while disabling the separate
    // software rasterizer, GPU raster and zero-copy buffer paths. Apply this
    // only to the top-level Valve Browser command line; Chromium propagates
    // its supported switches to its own children, while games and unrelated
    // MacWS applications remain untouched.
    bool cpuRendering = getenv("MACWS_STEAM_CPU_RENDERING") != NULL &&
        !MacWSSteamArgumentsHaveProcessType(arguments);
    static const char *const cpuPolicies[] = {
        "--disable-software-rasterizer",
        "--disable-gpu-rasterization",
        "--disable-zero-copy",
    };
    size_t additions = MacWSSteamArgumentPresent(arguments, "--no-sandbox")
        ? 0 : 1;
    if (cpuRendering) {
        for (size_t index = 0;
             index < sizeof(cpuPolicies) / sizeof(cpuPolicies[0]); index++) {
            if (!MacWSSteamArgumentPresent(arguments, cpuPolicies[index]))
                additions++;
        }
    }
    if (additions == 0) return NULL;

    char **result = calloc(count + additions + 1, sizeof(*result));
    if (!result) return NULL;
    for (size_t index = 0; index < count; index++)
        result[index] = arguments[index];
    size_t output = count;
    if (!MacWSSteamArgumentPresent(arguments, "--no-sandbox"))
        result[output++] = (char *)"--no-sandbox";
    if (cpuRendering) {
        for (size_t index = 0;
             index < sizeof(cpuPolicies) / sizeof(cpuPolicies[0]); index++) {
            if (!MacWSSteamArgumentPresent(arguments, cpuPolicies[index]))
                result[output++] = (char *)cpuPolicies[index];
        }
    }
    return result;
}

static int MacWSSteamCreateSimpleProcess(void *commandOrArguments, int flags,
                                         const char *workingDirectory) {
    bool diagnostics = getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS") != NULL;
    if (diagnostics) {
        fprintf(stderr,
                "[MacWSSteamProcess] entry command=%p flags=%#x cwd=%p "
                "steam=%s\n",
                commandOrArguments, flags,
                workingDirectory,
                MacWSIsSteamProcess() ? "yes" : "no");
        fflush(stderr);
    }
    if (getenv("MACWS_STEAM_PROCESS_TRACE_ONLY")) {
        return gMacWSOriginalCreateSimpleProcess ?
            gMacWSOriginalCreateSimpleProcess(
                commandOrArguments, flags, workingDirectory) : 0;
    }
    if (!MacWSIsSteamProcess() || (flags & 0x20) ||
        !(flags & (0x04 | 0x08 | 0x10))) {
        if (diagnostics) {
            fprintf(stderr,
                    "[MacWSSteamProcess] fallback to Valve implementation "
                    "flags=%#x\n", flags);
            fflush(stderr);
        }
        return gMacWSOriginalCreateSimpleProcess ?
            gMacWSOriginalCreateSimpleProcess(
                commandOrArguments, flags, workingDirectory) : 0;
    }

    char *shellArguments[4] = {0};
    char *shellCommand = NULL;
    char **parsedArguments = NULL;
    char *const *arguments = NULL;
    const char *executable = NULL;
    bool searchPath = false;

    if (flags & 0x08) {
        arguments = (char *const *)commandOrArguments;
        executable = arguments ? arguments[0] : NULL;
    } else if (flags & 0x10) {
        arguments = (char *const *)commandOrArguments;
        executable = arguments ? arguments[0] : NULL;
        searchPath = true;
    } else {
        // RE-confirmed in Valve's implementation: the bit-2 path prefixes
        // "exec " before /bin/sh -c. Preserve that exact contract. Omitting
        // the prefix left the shell itself alive after its chrooted fork path
        // failed, consuming one core until ChildProcessQuery timed out.
        parsedArguments = MacWSParseValveQuotedArguments(
            (const char *)commandOrArguments);
        if (parsedArguments) {
            arguments = parsedArguments;
            executable = parsedArguments[0];
        } else {
            if (asprintf(&shellCommand, "exec %s",
                         (const char *)commandOrArguments) < 0) {
                errno = ENOMEM;
                return 0;
            }
            shellArguments[0] = (char *)"sh";
            shellArguments[1] = (char *)"-c";
            shellArguments[2] = shellCommand;
            arguments = shellArguments;
            executable = "/bin/sh";
        }
    }
    if (!executable || !arguments) {
        errno = EINVAL;
        return 0;
    }

    char **policyArguments = MacWSArgumentsByAddingSteamBrowserPolicy(
        executable, arguments);
    if (policyArguments) arguments = policyArguments;
    if (diagnostics) {
        fprintf(stderr,
                "[MacWSSteamProcess] spawn request executable=%s flags=%#x "
                "cwd=%s argv0=%s argv1=%s\n",
                executable, flags, workingDirectory ?: "(null)",
                arguments[0] ?: "(null)", arguments[1] ?: "(null)");
        for (size_t index = 0; index < 96 && arguments[index]; index++) {
            fprintf(stderr, "[MacWSSteamProcess] argv[%zu]=%s\n",
                    index, arguments[index]);
        }
        fflush(stderr);
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        free(shellCommand);
        free(policyArguments);
        MacWSFreeParsedArguments(parsedArguments);
        errno = result;
        return 0;
    }
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        posix_spawn_file_actions_destroy(&actions);
        free(shellCommand);
        free(policyArguments);
        MacWSFreeParsedArguments(parsedArguments);
        errno = result;
        return 0;
    }

    if (workingDirectory && workingDirectory[0]) {
        // The iOS SDK marks this macOS ABI unavailable even though the
        // chroot's macOS libSystem exports it. Resolve the running image's
        // implementation without mutating the multithreaded parent's cwd.
        typedef int (*MacWSAddChdirFunction)(
            posix_spawn_file_actions_t *, const char *);
        MacWSAddChdirFunction addChdir = (MacWSAddChdirFunction)dlsym(
            RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
        result = addChdir ? addChdir(&actions, workingDirectory) : ENOSYS;
    }

    // Preserve Valve's actual process-group and signal-mask contract.
    // RE-confirmed in client 1785799196's arm64 libtier0_s.dylib:
    //   +0x40 fork
    //   +0x44 setpgrp; +0x48 setsid
    //   +0x60 sigprocmask(SIG_UNBLOCK, { SIGCHLD }, NULL)
    // Calling setpgrp first makes the child a process-group leader, so the
    // following setsid necessarily fails with EPERM; POSIX_SPAWN_SETSID was
    // therefore observably different (new session) from Valve's effective
    // contract. Build a new process group in the existing session and apply
    // the parent's mask with SIGCHLD removed atomically at spawn.
    short attributeFlags = 0;
    if (result == 0 && (flags & 0x02)) {
        result = posix_spawnattr_setpgroup(&attributes, 0);
        if (result == 0) attributeFlags |= POSIX_SPAWN_SETPGROUP;
    }
    sigset_t childSignalMask;
    if (result == 0 &&
        sigprocmask(SIG_SETMASK, NULL, &childSignalMask) != 0)
        result = errno;
    if (result == 0 && sigdelset(&childSignalMask, SIGCHLD) != 0)
        result = errno;
    if (result == 0) {
        result = posix_spawnattr_setsigmask(&attributes, &childSignalMask);
        if (result == 0) attributeFlags |= POSIX_SPAWN_SETSIGMASK;
    }
    if (result == 0)
        result = posix_spawnattr_setflags(&attributes, attributeFlags);

    pid_t child = 0;
    extern char **environ;
    if (result == 0) {
        result = searchPath ?
            posix_spawnp(&child, executable, &actions, &attributes,
                         (char *const *)arguments, environ) :
            posix_spawn(&child, executable, &actions, &attributes,
                        (char *const *)arguments, environ);
    }

    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    free(shellCommand);
    if (result != 0) {
        errno = result;
        if (diagnostics) {
            fprintf(stderr,
                    "[MacWSSteamProcess] spawn failed executable=%s "
                    "flags=%#x cwd=%s error=%d\n",
                    executable, flags,
                    workingDirectory ?: "(null)", result);
            fflush(stderr);
        }
        MacWSFreeParsedArguments(parsedArguments);
        free(policyArguments);
        return 0;
    }
    if (diagnostics) {
        fprintf(stderr,
                "[MacWSSteamProcess] spawn success executable=%s "
                "flags=%#x cwd=%s pid=%d\n",
                executable, flags, workingDirectory ?: "(null)", child);
        fflush(stderr);
    }
    MacWSFreeParsedArguments(parsedArguments);
    free(policyArguments);
    return child;
}

static void MacWSSteamProcessImageLoaded(const struct mach_header *header,
                                         intptr_t slide) {
    if (!MacWSIsSteamProcess()) return;
    Dl_info image = {0};
    if (dladdr(header, &image) && image.dli_fname &&
        strstr(image.dli_fname, "/libtier0_s.dylib")) {
        gMacWSOriginalCreateSimpleProcess =
            (MacWSCreateSimpleProcessFunction)MSFindSymbol(
                (MSImageRef)header, "_CreateSimpleProcess");
        if (getenv("MACWS_STEAM_PROCESS_DIAGNOSTICS")) {
            fprintf(stderr,
                    "[MacWSSteamProcess] resolved Valve implementation=%p "
                    "image=%s\n",
                    gMacWSOriginalCreateSimpleProcess, image.dli_fname);
            fflush(stderr);
        }
        // libtier0 may load after steamui. Revisit every already-mapped image
        // now that both sides of the adapter are valid; future images continue
        // through the normal add-image callback below.
        if (gMacWSOriginalCreateSimpleProcess) {
            for (uint32_t index = 0; index < _dyld_image_count(); index++) {
                MacWSRebindSteamProcessImport(
                    _dyld_get_image_header(index),
                    _dyld_get_image_vmaddr_slide(index));
            }
        }
    }
    MacWSRebindSteamProcessImport(header, slide);
}

__attribute__((constructor))
static void MacWSInstallSteamProcessCompatibility(void) {
    // Diagnostic isolation switch only. Production keeps the adapter enabled;
    // this lets a bounded run compare Valve's original fork path without
    // changing the shipped default.
    if (getenv("MACWS_DISABLE_STEAM_PROCESS_COMPAT")) return;
    if (MacWSIsSteamProcess()) {
        MacWSPrepareSteamAccessibilityRuntime();
        MacWSInstallSteamApplicationLaunchCompatibility();
        _dyld_register_func_for_add_image(MacWSSteamProcessImageLoaded);
        for (uint32_t index = 0; index < _dyld_image_count(); index++)
            MacWSSteamProcessImageLoaded(_dyld_get_image_header(index),
                                         _dyld_get_image_vmaddr_slide(index));
    }
}
