// Runtime Objective-C inventory for the actual iOS private frameworks on the
// test device. This avoids relying on a different SDK's private headers while
// deriving the foreground assertion API used by the production launcher.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL interesting(const char *name) {
    if (!name) return NO;
    NSString *value = [NSString stringWithUTF8String:name];
    NSArray<NSString *> *tokens = @[
        @"RBSAssertion", @"RBSConnection", @"RBSDomain",
        @"RBSProcessIdentity", @"RBSProcessIdentifier",
        @"RBSProcessPredicate", @"RBSProcessHandle", @"RBSTarget",
        @"RBSCPU", @"RBSJetsam", @"RBSHereditary",
        @"BKSProcessAssertion",
    ];
    for (NSString *token in tokens) {
        if ([value containsString:token]) return YES;
    }
    return NO;
}

static void dump_methods(Class cls, BOOL classMethods) {
    Class owner = classMethods ? object_getClass(cls) : cls;
    unsigned count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    for (unsigned index = 0; index < count; index++) {
        Method method = methods[index];
        printf("  %c %s types=%s\n", classMethods ? '+' : '-',
               sel_getName(method_getName(method)),
               method_getTypeEncoding(method) ?: "?");
    }
    free(methods);
}

int main(void) {
    @autoreleasepool {
        const char *frameworks[] = {
            "/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices",
            "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
        };
        for (unsigned index = 0;
             index < sizeof(frameworks) / sizeof(frameworks[0]); index++) {
            void *handle = dlopen(frameworks[index], RTLD_NOW | RTLD_LOCAL);
            printf("FRAMEWORK path=%s handle=%p error=%s\n", frameworks[index],
                   handle, handle ? "none" : (dlerror() ?: "unknown"));
        }

        int classCount = objc_getClassList(NULL, 0);
        __unsafe_unretained Class *classes =
            (__unsafe_unretained Class *)calloc((size_t)classCount,
                                                sizeof(*classes));
        classCount = objc_getClassList(classes, classCount);
        for (int index = 0; index < classCount; index++) {
            Class cls = classes[index];
            const char *name = class_getName(cls);
            if (!interesting(name)) continue;
            printf("CLASS %s superclass=%s size=%zu\n", name,
                   class_getSuperclass(cls)
                       ? class_getName(class_getSuperclass(cls)) : "(nil)",
                   class_getInstanceSize(cls));
            dump_methods(cls, YES);
            dump_methods(cls, NO);
        }
        free(classes);

        Class connectionClass = objc_getClass("RBSConnection");
        id connection = ((id (*)(id, SEL))objc_msgSend)(
            (id)connectionClass, sel_registerName("sharedInstance"));
        NSError *error = nil;
        id descriptors = ((id (*)(id, SEL, BOOL, NSError **))objc_msgSend)(
            connection,
            sel_registerName("assertionDescriptorsByPidWithFlattenedAttributes:error:"),
            YES, &error);
        printf("ASSERTIONS error=%s\n%s\n",
               error ? error.description.UTF8String : "none",
               descriptors ? [[descriptors description] UTF8String] : "(nil)");
        if ([descriptors isKindOfClass:NSDictionary.class]) {
            [(NSDictionary *)descriptors enumerateKeysAndObjectsUsingBlock:
                ^(id key, id value, BOOL *stop) {
                (void)stop;
                if (![value conformsToProtocol:@protocol(NSFastEnumeration)])
                    return;
                for (id descriptor in value) {
                    id explanation = [descriptor valueForKey:@"explanation"];
                    id target = [descriptor valueForKey:@"target"];
                    id attributes = [descriptor valueForKey:@"attributes"];
                    NSMutableArray<NSString *> *attributeLines =
                        [NSMutableArray array];
                    if ([attributes conformsToProtocol:
                            @protocol(NSFastEnumeration)]) {
                        for (id attribute in attributes) {
                            NSString *line = [[attribute description]
                                stringByReplacingOccurrencesOfString:@"\n"
                                                          withString:@" "];
                            [attributeLines addObject:line];
                        }
                    }
                    printf("DESC owner=%s explanation=%s target=%s attrs=%s\n",
                           [[key description] UTF8String],
                           [[explanation description] UTF8String],
                           [[target description] UTF8String],
                           [[attributeLines componentsJoinedByString:@" | "]
                               UTF8String]);
                }
            }];
        }
    }
    return 0;
}
