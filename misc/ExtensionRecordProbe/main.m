// Read-only probe for the macOS 13.4 LaunchServices record used by
// ExtensionFoundation's Settings extension discovery path.

@import Foundation;

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static id SendObject(id object, const char *selectorName) {
    return object ? ((id (*)(id, SEL))objc_msgSend)(
        object, sel_registerName(selectorName)) : nil;
}

static int RegisterPendingObjectiveCClasses(void) {
    typedef struct { uint32_t version; uint32_t flags; } ObjCImageInfo;
    typedef Class (*ReadClassPair)(Class, const void *);
    ReadClassPair readClassPair =
        (ReadClassPair)dlsym(RTLD_DEFAULT, "objc_readClassPair");
    if (!readClassPair) return -1;

    int realized = 0;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(imageIndex);
        if (!header) continue;
        unsigned long classListSize = 0;
        uint64_t *classList = (uint64_t *)getsectiondata(
            header, "__DATA_CONST", "__objc_classlist", &classListSize);
        if (!classList) classList = (uint64_t *)getsectiondata(
            header, "__DATA", "__objc_classlist", &classListSize);
        if (!classList || !classListSize) continue;

        unsigned long imageInfoSize = 0;
        ObjCImageInfo *imageInfo = (ObjCImageInfo *)getsectiondata(
            header, "__DATA_CONST", "__objc_imageinfo", &imageInfoSize);
        if (!imageInfo) imageInfo = (ObjCImageInfo *)getsectiondata(
            header, "__DATA", "__objc_imageinfo", &imageInfoSize);
        if (!imageInfo) imageInfo = (ObjCImageInfo *)getsectiondata(
            header, "__OBJC", "__image_info", &imageInfoSize);
        if (!imageInfo) continue;

        size_t classCount = classListSize / sizeof(uint64_t);
        for (int pass = 0; pass < 8; pass++) {
            int passRealized = 0;
            for (size_t classIndex = 0; classIndex < classCount;
                 classIndex++) {
                Class candidate = (Class)classList[classIndex];
                if (!candidate) continue;
                const char *name = class_getName(candidate);
                if (!name || !name[0] || objc_getClass(name)) continue;
                Class result = readClassPair(candidate, imageInfo);
                if (result && objc_getClass(name)) {
                    realized++;
                    passRealized++;
                }
            }
            if (!passRealized) break;
        }
    }
    return realized;
}

int main(void) {
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);
    @autoreleasepool {
        void *extensionFoundation = dlopen(
            "/System/Library/Frameworks/ExtensionFoundation.framework/"
            "ExtensionFoundation", RTLD_NOW | RTLD_LOCAL);
        printf("FRAMEWORK handle=%p error=%s\n", extensionFoundation,
               extensionFoundation ? "none" : (dlerror() ?: "unknown"));
        if (!extensionFoundation) return 1;
        if (getenv("MACWS_PROBE_EXTENSIONKIT_CONSTANTS")) {
            // Runtime addresses come directly from the current-boot
            // ExtensionFoundation 13.4 disassembly of
            // +[_EXDiscoveryController canRunQuery:error:] and
            // -extensionsMatchingQuery:.  This is diagnostic-only evidence,
            // not a production patch or an ABI dependency.
            const uintptr_t constantAddresses[] = {
                0x2322222b8ULL,
                0x2322222d8ULL,
                0x2322222f8ULL,
            };
            for (size_t index = 0;
                 index < sizeof(constantAddresses) /
                             sizeof(constantAddresses[0]); index++) {
                id value = (__bridge id)(const void *)constantAddresses[index];
                printf("EXTENSIONKIT_CONSTANT address=%p class=%s value=%s\n",
                       (const void *)constantAddresses[index],
                       value ? object_getClassName(value) : "nil",
                       value ? [[value description] UTF8String] : "nil");
            }
        }
        void *launchServices = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/"
            "Frameworks/LaunchServices.framework/Versions/A/LaunchServices",
            RTLD_NOW | RTLD_LOCAL);
        printf("LAUNCHSERVICES handle=%p error=%s\n", launchServices,
               launchServices ? "none" : (dlerror() ?: "unknown"));

        // lsregister itself uses this one-argument entry point when it imports
        // ExtensionKit plug-ins discovered by EXEnumerator. Keep the mutation
        // opt-in: the default probe remains read-mostly, while the diagnostic
        // mode exercises the same Ventura client/server path as database seed.
        if (getenv("MACWS_PROBE_REGISTER_ORIGINAL")) {
            if (getenv("MACWS_PROBE_STOP_BEFORE_REGISTER")) {
                printf("PRIVATE_REGISTER waiting-for-lldb pid=%d\n",
                       getpid());
                raise(SIGSTOP);
            }
            typedef int32_t (*LSRegisterPluginURL)(CFURLRef);
            LSRegisterPluginURL registerPluginURL =
                (LSRegisterPluginURL)dlsym(launchServices,
                                           "_LSRegisterPluginURL");
            NSURL *appearanceURL = [NSURL fileURLWithPath:
                @"/System/Library/ExtensionKit/Extensions/Appearance.appex"];
            BOOL wantsRegistrationDetail =
                getenv("MACWS_PROBE_REGISTER_DETAIL") != NULL;
            int32_t status = !wantsRegistrationDetail && registerPluginURL
                ? registerPluginURL((__bridge CFURLRef)appearanceURL)
                : INT32_MIN;
            printf("PRIVATE_REGISTER symbol=%p status=%d url=%s\n",
                   registerPluginURL, status,
                   appearanceURL.path.UTF8String);
            if (wantsRegistrationDetail) {
                typedef int32_t (*LSContextInit)(void *);
                typedef void (*LSContextDestroy)(void *);
                typedef BOOL (*LSRegisterPluginNode)(
                    void *, id, id, uint32_t, uint32_t, NSError **);
                LSContextInit contextInit = (LSContextInit)dlsym(
                    launchServices, "_LSContextInit");
                LSContextDestroy contextDestroy = (LSContextDestroy)dlsym(
                    launchServices, "_LSContextDestroy");
                LSRegisterPluginNode registerPluginNode =
                    (LSRegisterPluginNode)dlsym(
                        launchServices, "_LSRegisterPluginNode");
                // These three symbols are local in Ventura's LaunchServices
                // image, so dlsym normally cannot return them. libmachook has
                // already loaded Substrate; use its image-symbol resolver for
                // this opt-in diagnostic, matching the project's LLDB symbol
                // names exactly.
                typedef void *(*MSFindSymbolFn)(void *, const char *);
                MSFindSymbolFn findSymbol = (MSFindSymbolFn)dlsym(
                    RTLD_DEFAULT, "MSFindSymbol");
                Dl_info launchServicesInfo = {};
                if (findSymbol && registerPluginURL &&
                    dladdr((void *)registerPluginURL,
                           &launchServicesInfo) &&
                    launchServicesInfo.dli_fbase) {
                    void *image = (void *)launchServicesInfo.dli_fbase;
                    if (!contextInit) contextInit = (LSContextInit)findSymbol(
                        image, "__LSContextInit");
                    if (!contextDestroy)
                        contextDestroy = (LSContextDestroy)findSymbol(
                            image, "__LSContextDestroy");
                    if (!registerPluginNode)
                        registerPluginNode = (LSRegisterPluginNode)findSymbol(
                            image, "__LSRegisterPluginNode");
                }
                // RE-confirmed at _LSRegisterPluginURL+0x30 in Ventura 13.4:
                // the classref loaded immediately before objc_alloc is FSNode.
                Class builderClass = objc_getClass("FSNode");
                NSError *builderError = nil;
                id builder = ((id (*)(id, SEL))objc_msgSend)(
                    builderClass, sel_registerName("alloc"));
                builder = ((id (*)(id, SEL, id, NSUInteger, NSError **))
                    objc_msgSend)(
                        builder, sel_registerName("initWithURL:flags:error:"),
                        appearanceURL, 0, &builderError);
                uintptr_t context = 0;
                int32_t contextStatus = contextInit
                    ? contextInit(&context) : INT32_MIN;
                NSError *registrationError = nil;
                BOOL registrationResult = builder && !contextStatus &&
                    registerPluginNode
                    ? registerPluginNode(&context, builder, nil, 0, 0,
                                         &registrationError)
                    : NO;
                printf("PRIVATE_REGISTER_DETAIL builderClass=%p builder=%s "
                       "builderError=%s contextInit=%p contextStatus=%d "
                       "context=%p registerNode=%p result=%u error=%s\n",
                       builderClass,
                       builder ? [[builder description] UTF8String] : "nil",
                       builderError
                           ? [[builderError description] UTF8String] : "nil",
                       contextInit, contextStatus, (void *)context,
                       registerPluginNode, registrationResult ? 1 : 0,
                       registrationError
                           ? [[registrationError description] UTF8String]
                           : "nil");
                if (contextDestroy && !contextStatus)
                    contextDestroy(&context);
            }
        }
        int realizedClasses = RegisterPendingObjectiveCClasses();
        printf("OBJC_PREREGISTER realized=%d LSPlugInKitProxy=%p\n",
               realizedClasses, objc_getClass("LSPlugInKitProxy"));

        // Capture the exact Objective-C ABI of the late ExtensionFoundation
        // entry point before installing a boundary hook in libmachook.  This
        // keeps the production wrapper tied to runtime metadata from the
        // actual Ventura framework rather than a guessed private signature.
        Class runningExtensionClass = objc_getClass("_EXRunningExtension");
        Method startMethod = class_getInstanceMethod(
            runningExtensionClass,
            sel_registerName("_startWithArguments:count:"));
        printf("RUNNING_EXTENSION class=%p method=%p types=%s imp=%p\n",
               runningExtensionClass, startMethod,
               startMethod ? method_getTypeEncoding(startMethod) : "nil",
               startMethod ? method_getImplementation(startMethod) : NULL);

        NSString *identifier = @"com.apple.Appearance-Settings.extension";
        NSURL *embeddedProxyURL = [NSURL fileURLWithPath:
            @"/private/var/jb/Applications/MacWSCatalystLauncher.app/"
             "PlugIns/SettingsExtensionProxy.appex"];
        Class workspaceClass = objc_getClass("LSApplicationWorkspace");
        Method defaultWorkspaceMethod = class_getClassMethod(
            workspaceClass, sel_registerName("defaultWorkspace"));
        Method registerPluginMethod = class_getInstanceMethod(
            workspaceClass, sel_registerName("registerPlugin:"));
        printf("WORKSPACE class=%p defaultTypes=%s registerTypes=%s\n",
               workspaceClass,
               defaultWorkspaceMethod
                   ? method_getTypeEncoding(defaultWorkspaceMethod) : "nil",
               registerPluginMethod
                   ? method_getTypeEncoding(registerPluginMethod) : "nil");
        id workspace = ((id (*)(id, SEL))objc_msgSend)(
            workspaceClass, sel_registerName("defaultWorkspace"));
        NSURL *carrierURL = [NSURL fileURLWithPath:
            @"/private/var/jb/Applications/MacWSCatalystLauncher.app"];
        BOOL applicationRegistered = ((BOOL (*)(id, SEL, id))objc_msgSend)(
            workspace, sel_registerName("registerApplication:"), carrierURL);
        printf("WORKSPACE registerApplication=%u url=%s\n",
               applicationRegistered ? 1 : 0, carrierURL.path.UTF8String);
        BOOL registered = ((BOOL (*)(id, SEL, id))objc_msgSend)(
            workspace, sel_registerName("registerPlugin:"), embeddedProxyURL);
        printf("WORKSPACE registerPlugin=%u url=%s\n", registered ? 1 : 0,
               embeddedProxyURL.path.UTF8String);
        NSURL *originalAppearanceURL = [NSURL fileURLWithPath:
            @"/System/Library/ExtensionKit/Extensions/Appearance.appex"];
        BOOL originalRegistered = ((BOOL (*)(id, SEL, id))objc_msgSend)(
            workspace, sel_registerName("registerPlugin:"),
            originalAppearanceURL);
        printf("WORKSPACE registerOriginalPlugin=%u url=%s\n",
               originalRegistered ? 1 : 0,
               originalAppearanceURL.path.UTF8String);
        Class concreteExtensionClass = objc_getClass("EXConcreteExtension");
        id concreteError = nil;
        id concreteExtension = ((id (*)(id, SEL, id, id *))objc_msgSend)(
            concreteExtensionClass,
            sel_registerName("extensionWithIdentifier:error:"), identifier,
            &concreteError);
        printf("CONCRETE class=%s value=%s error=%s\n",
               concreteExtension ? object_getClassName(concreteExtension) : "nil",
               concreteExtension ? [[concreteExtension description] UTF8String] : "nil",
               concreteError ? [[concreteError description] UTF8String] : "nil");
        Class queryClass = objc_getClass("_EXQuery");
        id query = ((id (*)(id, SEL, id))objc_msgSend)(
            queryClass, sel_registerName("extensionPointIdentifierQuery:"),
            @"com.apple.Settings.extension.ui");
        id queryPointRecords = SendObject(query, "extensionPointRecords");
        unsigned long long queryResultType =
            ((unsigned long long (*)(id, SEL))objc_msgSend)(
                query, sel_registerName("resultType"));
        BOOL queryPostprocessing = ((BOOL (*)(id, SEL))objc_msgSend)(
            query, sel_registerName("includePostprocessing"));
        printf("QUERY_STATE class=%s pointRecordCount=%lu resultType=%llu "
               "postprocessing=%u pointRecords=%s\n",
               query ? object_getClassName(query) : "nil",
               (unsigned long)[queryPointRecords count], queryResultType,
               queryPostprocessing ? 1 : 0,
               queryPointRecords
                   ? [[queryPointRecords description] UTF8String] : "nil");
        Class discoveryControllerClass =
            objc_getClass("_EXDiscoveryController");
        NSError *queryAdmissionError = nil;
        BOOL queryCanRun =
            ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
                discoveryControllerClass,
                sel_registerName("canRunQuery:error:"), query,
                &queryAdmissionError);
        Class defaultsClassForAdmission = objc_getClass("_EXDefaults");
        id defaultsForAdmission = ((id (*)(id, SEL))objc_msgSend)(
            defaultsClassForAdmission, sel_registerName("sharedInstance"));
        BOOL forceSandbox = ((BOOL (*)(id, SEL))objc_msgSend)(
            defaultsForAdmission, sel_registerName("forceSandbox"));
        id allowedUnsandboxed = SendObject(
            defaultsForAdmission, "allowedUnsandboxedExtensionPoints");
        printf("QUERY_ADMISSION canRun=%u error=%s forceSandbox=%u "
               "allowedUnsandboxed=%s\n",
               queryCanRun ? 1 : 0,
               queryAdmissionError
                   ? [[queryAdmissionError description] UTF8String] : "nil",
               forceSandbox ? 1 : 0,
               allowedUnsandboxed
                   ? [[allowedUnsandboxed description] UTF8String] : "nil");
        if (getenv("MACWS_PROBE_QUERY_POINT_ENUMERATOR")) {
            id queryPointRecord = [queryPointRecords firstObject];
            Class recordClassForQuery =
                objc_getClass("LSApplicationExtensionRecord");
            id recordEnumerator = ((id (*)(id, SEL, id,
                                            unsigned long long))objc_msgSend)(
                recordClassForQuery,
                sel_registerName("enumeratorWithExtensionPointRecord:options:"),
                queryPointRecord, 0);
            NSUInteger recordCount = 0;
            NSUInteger matchCount = 0;
            for (; recordCount < 10000; recordCount++) {
                id candidate = SendObject(recordEnumerator, "nextObject");
                if (!candidate) break;
                BOOL matches = ((BOOL (*)(id, SEL, id))objc_msgSend)(
                    query, sel_registerName("matchesRecord:"), candidate);
                if (matches) matchCount++;
                if (recordCount < 5 || matches) {
                    printf("QUERY_ENUM_RECORD index=%lu class=%s id=%s "
                           "platform=%u matches=%u url=%s\n",
                           (unsigned long)recordCount,
                           object_getClassName(candidate),
                           [[SendObject(candidate, "bundleIdentifier")
                               description] UTF8String],
                           ((unsigned (*)(id, SEL))objc_msgSend)(
                               candidate, sel_registerName("platform")),
                           matches ? 1 : 0,
                           [[SendObject(candidate, "URL") description]
                               UTF8String]);
                }
            }
            printf("QUERY_ENUM_SUMMARY pointRecord=%s enumeratorClass=%s "
                   "recordCount=%lu matchCount=%lu\n",
                   queryPointRecord
                       ? [[queryPointRecord description] UTF8String] : "nil",
                   recordEnumerator
                       ? object_getClassName(recordEnumerator) : "nil",
                   (unsigned long)recordCount, (unsigned long)matchCount);
        }
        id queryResults = ((id (*)(id, SEL, id))objc_msgSend)(
            queryClass, sel_registerName("executeQuery:"), query);
        printf("QUERY resultCount=%lu results=%s\n",
               (unsigned long)[queryResults count],
               queryResults ? [[queryResults description] UTF8String] : "nil");
        if (getenv("MACWS_PROBE_QUERY_ROUTES")) {
            Class defaultsClass = objc_getClass("_EXDefaults");
            id defaults = ((id (*)(id, SEL))objc_msgSend)(
                defaultsClass, sel_registerName("sharedInstance"));
            BOOL preferInProcess = ((BOOL (*)(id, SEL))objc_msgSend)(
                defaults, sel_registerName("preferInProcessDiscovery"));
            NSArray *queries = query ? @[query] : @[];
            Class discoveryClass = objc_getClass("_EXDiscoveryController");
            id discovery = ((id (*)(id, SEL))objc_msgSend)(
                discoveryClass, sel_registerName("sharedInstance"));
            id discoveryResult = ((id (*)(id, SEL, id))objc_msgSend)(
                discovery, sel_registerName("extensionsMatchingQueries:"),
                queries);
            id discoveryIdentities = SendObject(discoveryResult,
                                                 "identities");
            id discoverySingleResult =
                ((id (*)(id, SEL, id))objc_msgSend)(
                    discovery,
                    sel_registerName("extensionsMatchingQuery:"), query);
            id discoverySingleIdentities = SendObject(
                discoverySingleResult, "identities");
            printf("QUERY_ROUTE defaults=%s preferInProcess=%u "
                   "discovery=%s resultClass=%s identitiesCount=%lu "
                   "identities=%s singleResultClass=%s "
                   "singleIdentitiesCount=%lu singleIdentities=%s\n",
                   defaults ? object_getClassName(defaults) : "nil",
                   preferInProcess ? 1 : 0,
                   discovery ? object_getClassName(discovery) : "nil",
                   discoveryResult ? object_getClassName(discoveryResult)
                                   : "nil",
                   (unsigned long)[discoveryIdentities count],
                   discoveryIdentities
                       ? [[discoveryIdentities description] UTF8String]
                       : "nil",
                   discoverySingleResult
                       ? object_getClassName(discoverySingleResult) : "nil",
                   (unsigned long)[discoverySingleIdentities count],
                   discoverySingleIdentities
                       ? [[discoverySingleIdentities description] UTF8String]
                       : "nil");

            Class serviceClass = objc_getClass("_EXServiceClient");
            id service = ((id (*)(id, SEL))objc_msgSend)(
                serviceClass, sel_registerName("sharedInstance"));
            id serviceResult = ((id (*)(id, SEL, id))objc_msgSend)(
                service, sel_registerName("extensionsWithQueries:"), queries);
            id serviceIdentities = SendObject(serviceResult, "identities");
            printf("QUERY_ROUTE service=%s resultClass=%s "
                   "identitiesCount=%lu identities=%s\n",
                   service ? object_getClassName(service) : "nil",
                   serviceResult ? object_getClassName(serviceResult) : "nil",
                   (unsigned long)[serviceIdentities count],
                   serviceIdentities
                       ? [[serviceIdentities description] UTF8String]
                       : "nil");
        }
        Class enumeratorClass = objc_getClass("EXEnumerator");
        Class catalogClass = objc_getClass("EXExtensionPointCatalog");
        id pointEnumerator = ((id (*)(id, SEL))objc_msgSend)(
            enumeratorClass,
            sel_registerName("extensionPointDefinitionEnumerator"));
        id catalog = ((id (*)(id, SEL))objc_msgSend)(
            catalogClass, sel_registerName("alloc"));
        catalog = ((id (*)(id, SEL, id))objc_msgSend)(
            catalog, sel_registerName("initWithEnumerator:"), pointEnumerator);
        id point = ((id (*)(id, SEL, id))objc_msgSend)(
            catalog, sel_registerName("extensionPointForIdentifier:"),
            @"com.apple.Settings.extension.ui");
        id pointQuery = ((id (*)(id, SEL))objc_msgSend)(
            queryClass, sel_registerName("alloc"));
        pointQuery = ((id (*)(id, SEL, id))objc_msgSend)(
            pointQuery, sel_registerName("initWithExtensionPoint:"), point);
        id pointQueryRecords = SendObject(pointQuery,
                                          "extensionPointRecords");
        printf("POINT_QUERY_STATE pointRecordCount=%lu pointRecords=%s\n",
               (unsigned long)[pointQueryRecords count],
               pointQueryRecords
                   ? [[pointQueryRecords description] UTF8String] : "nil");
        id pointQueryResults = ((id (*)(id, SEL, id))objc_msgSend)(
            queryClass, sel_registerName("executeQuery:"), pointQuery);
        printf("POINT_QUERY point=%s resultCount=%lu\n",
               point ? [[point description] UTF8String] : "nil",
               (unsigned long)[pointQueryResults count]);
        Class recordClass = objc_getClass("LSApplicationExtensionRecord");
        id embeddedError = nil;
        id embeddedRecord = ((id (*)(id, SEL))objc_msgSend)(
            recordClass, sel_registerName("alloc"));
        embeddedRecord = ((id (*)(id, SEL, id, id *))objc_msgSend)(
            embeddedRecord, sel_registerName("initWithURL:error:"),
            embeddedProxyURL, &embeddedError);
        printf("EMBEDDED_RECORD class=%s value=%s error=%s\n",
               embeddedRecord ? object_getClassName(embeddedRecord) : "nil",
               embeddedRecord ? [[embeddedRecord description] UTF8String] : "nil",
               embeddedError ? [[embeddedError description] UTF8String] : "nil");
        if (embeddedRecord) {
            unsigned embeddedPlatform = ((unsigned (*)(id, SEL))objc_msgSend)(
                embeddedRecord, sel_registerName("platform"));
            id embeddedPoint = SendObject(embeddedRecord,
                                          "extensionPointRecord");
            printf("EMBEDDED_RECORD platform=%u point=%s url=%s\n",
                   embeddedPlatform,
                   embeddedPoint ? [[embeddedPoint description] UTF8String] : "nil",
                   [[SendObject(embeddedRecord, "URL") description] UTF8String]);
        }
        Class proxyClass = objc_getClass("LSPlugInKitProxy");
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(
            proxyClass, sel_registerName("pluginKitProxyForIdentifier:"),
            identifier);
        id proxyPlatform = SendObject(proxy, "platform");
        id proxyPoint = SendObject(proxy, "extensionPoint");
        id record = SendObject(proxy,
                               "correspondingApplicationExtensionRecord");
        printf("PROXY class=%s platform=%s point=%s\n",
               proxy ? object_getClassName(proxy) : "nil",
               proxyPlatform ? [[proxyPlatform description] UTF8String] : "nil",
               proxyPoint ? [[proxyPoint description] UTF8String] : "nil");
        if (!record) {
            printf("RECORD nil\n");
            return 2;
        }

        unsigned platform = ((unsigned (*)(id, SEL))objc_msgSend)(
            record, sel_registerName("platform"));
        id recordIdentifier = SendObject(record, "bundleIdentifier");
        id recordURL = SendObject(record, "URL");
        id pointRecord = SendObject(record, "extensionPointRecord");
        printf("RECORD class=%s platform=%u identifier=%s url=%s\n",
               object_getClassName(record), platform,
               [[recordIdentifier description] UTF8String],
               [[recordURL description] UTF8String]);
        printf("POINT_RECORD class=%s value=%s\n",
               pointRecord ? object_getClassName(pointRecord) : "nil",
               pointRecord ? [[pointRecord description] UTF8String] : "nil");

        if (getenv("MACWS_PROBE_DETACHED_ENUMERATOR")) {
            id enumerator = ((id (*)(id, SEL, id,
                                      unsigned long long))objc_msgSend)(
                recordClass,
                sel_registerName("enumeratorWithExtensionPointRecord:options:"),
                pointRecord, 0);
            NSUInteger count = 0;
            BOOL foundAppearance = NO;
            for (; count < 10000; count++) {
                id candidate = SendObject(enumerator, "nextObject");
                if (!candidate) break;
                id candidateIdentifier = SendObject(candidate, "bundleIdentifier");
                if ([candidateIdentifier isEqual:identifier]) {
                    foundAppearance = YES;
                }
            }
            printf("ENUMERATOR class=%s count=%lu foundAppearance=%u\n",
                   enumerator ? object_getClassName(enumerator) : "nil",
                   (unsigned long)count, foundAppearance ? 1 : 0);
        }

        id urlError = nil;
        id urlRecord = ((id (*)(id, SEL))objc_msgSend)(
            recordClass, sel_registerName("alloc"));
        urlRecord = ((id (*)(id, SEL, id, id *))objc_msgSend)(
            urlRecord, sel_registerName("initWithURL:error:"), recordURL,
            &urlError);
        printf("URL_RECORD class=%s value=%s error=%s\n",
               urlRecord ? object_getClassName(urlRecord) : "nil",
               urlRecord ? [[urlRecord description] UTF8String] : "nil",
               urlError ? [[urlError description] UTF8String] : "nil");

        if (getenv("MACWS_PROBE_DETACHED_IDENTITY")) {
            Class identityClass = objc_getClass("_EXExtensionRecordIdentity");
            id identity = ((id (*)(id, SEL))objc_msgSend)(
                identityClass, sel_registerName("alloc"));
            identity = ((id (*)(id, SEL, id))objc_msgSend)(
                identity,
                sel_registerName("initWithApplicationExtensionRecord:"), record);
            printf("IDENTITY class=%s value=%s\n",
                   identity ? object_getClassName(identity) : "nil",
                   identity ? [[identity description] UTF8String] : "nil");
        }

        unsigned classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned classIndex = 0; classIndex < classCount; classIndex++) {
            Class candidateClass = classes[classIndex];
            const char *image = class_getImageName(candidateClass);
            if (!image || !strstr(image, "LaunchServices.framework")) continue;
            Class owners[2] = {candidateClass, object_getClass(candidateClass)};
            const char kinds[2] = {'-', '+'};
            for (unsigned ownerIndex = 0; ownerIndex < 2; ownerIndex++) {
                unsigned methodCount = 0;
                Method *methods = class_copyMethodList(owners[ownerIndex],
                                                       &methodCount);
                for (unsigned methodIndex = 0; methodIndex < methodCount;
                     methodIndex++) {
                    const char *selector = sel_getName(
                        method_getName(methods[methodIndex]));
                    if (!strstr(selector, "register") &&
                        !strstr(selector, "Register") &&
                        !strstr(selector, "plugin") &&
                        !strstr(selector, "Plugin") &&
                        !strstr(selector, "applicationExtension")) {
                        continue;
                    }
                    printf("LSINVENTORY class=%s kind=%c selector=%s types=%s\n",
                           class_getName(candidateClass), kinds[ownerIndex],
                           selector,
                           method_getTypeEncoding(methods[methodIndex]));
                }
                free(methods);
            }
        }
        free(classes);
        const char *targetClassNames[] = {
            "_LSInstaller", "LSBundleRecordBuilder", "_LSDModifyClient", NULL
        };
        for (const char *const *name = targetClassNames; *name; name++) {
            Class targetClass = objc_getClass(*name);
            printf("LSTARGET class=%s value=%p\n", *name, targetClass);
            if (!targetClass) continue;
            Class owners[2] = {targetClass, object_getClass(targetClass)};
            const char kinds[2] = {'-', '+'};
            for (unsigned ownerIndex = 0; ownerIndex < 2; ownerIndex++) {
                unsigned methodCount = 0;
                Method *methods = class_copyMethodList(owners[ownerIndex],
                                                       &methodCount);
                for (unsigned methodIndex = 0; methodIndex < methodCount;
                     methodIndex++) {
                    printf("LSTARGET class=%s kind=%c selector=%s types=%s\n",
                           *name, kinds[ownerIndex],
                           sel_getName(method_getName(methods[methodIndex])),
                           method_getTypeEncoding(methods[methodIndex]));
                }
                free(methods);
            }
        }
    }
    return 0;
}
