"""Execute the real namespace adapters with controlled kernel/provider inputs.

This is not a device fork/Preview acceptance test. Those additionally require
the installed dyld interpose bindings and real rendered document output.
"""
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ChrootMountNamespace(unittest.TestCase):
    def test_default_namespace_is_not_selected_by_process_or_feature_flags(self):
        source = (ROOT / "libmachook/Metal_hooks.x").read_text()
        start = source.index("static void macws_rebase_application_mount_namespace(")
        end = source.index("static const char *macws_lp_utf8", start)
        namespace = source[start:end]
        for retired in ("macws_needs_application_mount_namespace_compatibility",
                        'getenv("MACWS_APP_MOUNT_COMPAT")',
                        'getenv("MACWS_APP_MOUNT_COMPAT_DIAGNOSTIC")'):
            self.assertNotIn(retired, source)
        self.assertFalse(re.search(r"\bMSHookFunction\s*\(", namespace),
                         "namespace adapters must not modify shared executable text")
        for original, replacement in (
                ("statfs", "macws_lp_statfs_namespace_compat"),
                ("fstatfs", "macws_lp_fstatfs_namespace_compat"),
                ("fsgetpath", "macws_fsgetpath_namespace_compat"),
                ("CFURLCopyResourcePropertyForKey", "macws_cfurl_copy_resource_property_compat"),
                ("CFURLCopyResourcePropertiesForKeys", "macws_cfurl_copy_resource_properties_compat")):
            self.assertRegex(namespace, rf"DYLD_INTERPOSE\({replacement},\s*{original}\)")
        constructor = source[source.index("__attribute__((constructor)) static void InitMetalHooks()") :]
        self.assertLess(constructor.index("macws_initialize_chroot_mount_namespace();"),
                        constructor.index("return;"))

    @unittest.skipUnless(platform.system() == "Darwin", "requires Darwin CFURL/statfs ABI")
    def test_real_adapter_functions_preserve_namespace_and_ownership(self):
        compiler = shutil.which("clang")
        if not compiler:
            self.skipTest("requires host clang")
        source = (ROOT / "libmachook/Metal_hooks.x").read_text()
        start = source.index("static void macws_rebase_application_mount_namespace(")
        end = source.index("static const char *macws_lp_utf8", start)
        functions = source[start:end]
        harness = r'''
#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <sys/mount.h>
#include <sys/fsgetpath.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static BOOL macws_chroot_root_mount_needs_rebase;
static fsid_t macws_chroot_root_fsid;
static char macws_chroot_root_host_mount[MAXPATHLEN];
static char macws_chroot_host_root[MAXPATHLEN];
static const char *test_host_root;
static const char *test_mount = "/private/var";
static const char *test_kernel_path;
static int test_stat_error, test_zero_fsid, provider_calls, fcntl_calls, path_calls, trace;
static int ns_provider_calls, method_install_calls;
static Boolean provider_success = true;
static CFURLRef provider_value;
static char *test_getenv(const char *name) {
    if (strcmp(name, "MACWS_CHROOT_HOST_ROOT") == 0) return (char *)test_host_root;
    return trace && !strcmp(name, "MACWS_APP_MOUNT_TRACE") ? "1" : NULL;
}
static int test_statfs(const char *path, struct statfs *value) {
    if (test_stat_error) return -1;
    memset(value, 0, sizeof(*value));
    value->f_fsid.val[0] = test_zero_fsid ? 0 : 10;
    value->f_fsid.val[1] = test_zero_fsid ? 0 : 20;
    if (strncmp(path, "/other", 6) == 0) value->f_fsid.val[1] = 21;
    strlcpy(value->f_mntonname, test_mount, sizeof(value->f_mntonname));
    return 0;
}
static int test_fstatfs(int descriptor, struct statfs *value) {
    (void)descriptor; return test_statfs("/", value);
}
static int test_fcntl(int descriptor, int command, ...) {
    (void)descriptor; (void)command; fcntl_calls++; return -1;
}
static Boolean test_url_path(CFURLRef url, Boolean resolve, UInt8 *bytes, CFIndex capacity) {
    path_calls++;
    return CFURLGetFileSystemRepresentation(url, resolve, bytes, capacity);
}
static ssize_t test_fsgetpath(char *out, size_t capacity, fsid_t *fsid, uint64_t object) {
    (void)fsid; (void)object;
    if (strlen(test_kernel_path) + 1 > capacity) { errno = ERANGE; return -1; }
    strcpy(out, test_kernel_path);
    return strlen(out) + 1;
}
static Boolean test_cfurl_property(CFURLRef url, CFStringRef key, void *value, CFErrorRef *error) {
    (void)url; (void)key; (void)error;
    provider_calls++;
    if (provider_success && value) *(CFTypeRef *)value = provider_value ? CFRetain(provider_value) : NULL;
    return provider_success;
}
static IMP test_install_method(Method method, IMP replacement) {
    (void)replacement; method_install_calls++; return method_getImplementation(method);
}
static BOOL test_ns_resource(id self, SEL selector, id *value, id key, id *error) {
    (void)self; (void)selector; (void)key;
    ns_provider_calls++;
    if (!provider_success) { if (error) *error = @"native-error"; return NO; }
    if (value) *value = (id)provider_value;
    return YES;
}
static id test_ns_resources(id self, SEL selector, id keys, id *error) {
    (void)self; (void)selector;
    ns_provider_calls++;
    if (!provider_success) { if (error) *error = @"native-error"; return nil; }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (id key in keys) result[key] = [key isEqual:@"NSURLNameKey"] ? @"native-name" : (id)provider_value;
    return result;
}
static CFDictionaryRef test_cfurl_properties(CFURLRef url, CFArrayRef keys, CFErrorRef *error) {
    id result = test_ns_resources((id)url, NULL, (id)keys, (id *)error);
    return result ? (CFDictionaryRef)CFRetain((CFTypeRef)result) : NULL;
}
#define getenv test_getenv
#define statfs(path, value) test_statfs(path, value)
#define fstatfs test_fstatfs
#define fcntl test_fcntl
#define fsgetpath test_fsgetpath
#define CFURLCopyResourcePropertyForKey test_cfurl_property
#define CFURLCopyResourcePropertiesForKeys test_cfurl_properties
#define CFURLGetFileSystemRepresentation test_url_path
#define method_setImplementation test_install_method
#define DYLD_INTERPOSE(replacement, original)
''' + functions + r'''
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "line %d: %s\n", __LINE__, #condition); return 1; } } while (0)
static void reset_namespace(void) {
    macws_chroot_root_mount_needs_rebase = NO;
    memset(&macws_chroot_root_fsid, 0, sizeof(macws_chroot_root_fsid));
    memset(macws_chroot_root_host_mount, 0, sizeof(macws_chroot_root_host_mount));
    memset(macws_chroot_host_root, 0, sizeof(macws_chroot_host_root));
    test_stat_error = test_zero_fsid = provider_calls = fcntl_calls = path_calls = trace = 0;
    test_mount = "/private/var";
}
static CFURLRef url(const char *path) {
    return CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
}
static Boolean url_is(CFURLRef value, const char *path) {
    char actual[MAXPATHLEN] = {};
    return value && CFURLGetFileSystemRepresentation(value, true, (UInt8 *)actual, sizeof(actual)) && !strcmp(actual, path);
}
int main(void) {
    @autoreleasepool {
        const char *invalid[] = {NULL, "", "/", "relative", "//a", "/a/", "/a/../b", "/a/./b", "/.", "/a/.."};
        for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
            reset_namespace(); test_host_root = invalid[i];
            macws_initialize_chroot_mount_namespace();
            CHECK(!macws_chroot_root_mount_needs_rebase);
            struct statfs fs = {};
            test_statfs("/", &fs); macws_rebase_application_mount_namespace("/", &fs);
            CHECK(!strcmp(fs.f_mntonname, "/private/var"));
        }
        test_host_root = "/private/var/mnt/rootfs";
        for (int scenario = 0; scenario < 3; scenario++) {
            reset_namespace();
            if (scenario == 0) test_mount = "/";
            if (scenario == 1) test_stat_error = 1;
            if (scenario == 2) test_zero_fsid = 1;
            macws_initialize_chroot_mount_namespace();
            CHECK(!macws_chroot_root_mount_needs_rebase);
        }
        reset_namespace(); macws_initialize_chroot_mount_namespace();
        CHECK(macws_chroot_root_mount_needs_rebase);
        CHECK(method_install_calls == 4);
        struct statfs fs = {};
        CHECK(macws_lp_statfs_namespace_compat("/tmp/document.pdf", &fs) == 0);
        CHECK(!strcmp(fs.f_mntonname, "/"));
        CHECK(macws_lp_statfs_namespace_compat("/other/document.pdf", &fs) == 0);
        CHECK(!strcmp(fs.f_mntonname, "/private/var"));
        CHECK(macws_lp_fstatfs_namespace_compat(42, &fs) == 0);
        CHECK(!strcmp(fs.f_mntonname, "/") && fcntl_calls == 0);
        trace = 1;
        CHECK(macws_lp_fstatfs_namespace_compat(42, &fs) == 0);
        CHECK(!strcmp(fs.f_mntonname, "/") && fcntl_calls == 1);
        trace = 0;
        CFURLRef root = url("/"), document = url("/tmp/document.pdf"), other = url("/other/document.pdf");
        CFURLRef value = NULL;
        CFErrorRef error = (CFErrorRef)1;
        provider_value = url("/private/var");
        path_calls = 0;
        CHECK(macws_cfurl_copy_resource_property_compat(document, CFSTR("NSURLNameKey"), &value, &error));
        CHECK(path_calls == 0); CFRelease(value); value = NULL; provider_calls = 0;
        CHECK(macws_cfurl_copy_resource_property_compat(root, CFSTR("NSURLParentDirectoryURLKey"), &value, &error));
        CHECK(!value && !error && provider_calls == 0);
        CHECK(macws_cfurl_copy_resource_property_compat(document, CFSTR("NSURLVolumeURLKey"), &value, &error));
        CHECK(url_is(value, "/") && provider_calls == 1); CFRelease(value);
        CHECK(macws_cfurl_copy_resource_property_compat(other, CFSTR("NSURLVolumeURLKey"), &value, &error));
        CHECK(url_is(value, "/private/var")); CFRelease(value);
        CHECK(macws_cfurl_copy_resource_property_compat(document, CFSTR("NSURLParentDirectoryURLKey"), &value, &error));
        CHECK(url_is(value, "/private/var")); CFRelease(value);
        CFRelease(provider_value); provider_value = url("/different-volume");
        CHECK(macws_cfurl_copy_resource_property_compat(document, CFSTR("NSURLVolumeURLKey"), &value, &error));
        CHECK(url_is(value, "/different-volume")); CFRelease(value);
        CFRelease(provider_value); provider_value = url("/private/var");
        macws_url_get_resource_original = test_ns_resource;
        macws_url_get_promised_resource_original = test_ns_resource;
        macws_url_get_resources_original = test_ns_resources;
        macws_url_get_promised_resources_original = test_ns_resources;
        SEL single = sel_registerName("getResourceValue:forKey:error:");
        SEL promised = sel_registerName("getPromisedItemResourceValue:forKey:error:");
        id nsValue = nil, nsError = @"sentinel";
        CHECK(macws_nsurl_get_resource((id)root, single, &nsValue, (id)kCFURLParentDirectoryURLKey, &nsError));
        CHECK(!nsValue && !nsError && ns_provider_calls == 0);
        CHECK(macws_nsurl_get_resource((id)document, single, &nsValue, (id)kCFURLVolumeURLKey, &nsError));
        CHECK(url_is((CFURLRef)nsValue, "/"));
        CHECK(macws_nsurl_get_resource((id)document, promised, &nsValue, (id)kCFURLVolumeURLKey, &nsError));
        CHECK(url_is((CFURLRef)nsValue, "/"));
        path_calls = 0;
        CHECK(macws_nsurl_get_resource((id)document, single, &nsValue, @"NSURLNameKey", &nsError));
        CHECK(path_calls == 0 && nsValue == (id)provider_value);
        NSArray *keys = @[(id)kCFURLParentDirectoryURLKey, (id)kCFURLVolumeURLKey, @"NSURLNameKey"];
        for (NSString *selector in @[@"resourceValuesForKeys:error:", @"promisedItemResourceValuesForKeys:error:"]) {
            NSDictionary *values = macws_nsurl_get_resources((id)root, NSSelectorFromString(selector), keys, &nsError);
            CHECK(!values[(id)kCFURLParentDirectoryURLKey]);
            CHECK(url_is((CFURLRef)values[(id)kCFURLVolumeURLKey], "/"));
            CHECK([values[@"NSURLNameKey"] isEqual:@"native-name"]);
        }
        CFDictionaryRef values = macws_cfurl_copy_resource_properties_compat(root, (CFArrayRef)keys, NULL);
        CHECK(values && !CFDictionaryContainsKey(values, kCFURLParentDirectoryURLKey));
        CHECK(url_is((CFURLRef)CFDictionaryGetValue(values, kCFURLVolumeURLKey), "/"));
        CFRelease(values);
        provider_success = false;
        nsValue = @"unchanged";
        CHECK(!macws_nsurl_get_resource((id)document, single, &nsValue, (id)kCFURLVolumeURLKey, &nsError));
        CHECK([nsValue isEqual:@"unchanged"] && [nsError isEqual:@"native-error"]);
        CHECK(!macws_nsurl_get_resources((id)document, sel_registerName("resourceValuesForKeys:error:"), keys, &nsError));
        CHECK([nsError isEqual:@"native-error"]);
        CHECK(!macws_cfurl_copy_resource_properties_compat(document, (CFArrayRef)keys, NULL));
        CHECK(!macws_cfurl_copy_resource_property_compat(document, CFSTR("NSURLVolumeURLKey"), NULL, &error));
        CFRelease(provider_value); CFRelease(root); CFRelease(document); CFRelease(other);
        const char *kernel[] = {"/private/var/mnt/rootfs", "/private/var/mnt/rootfs/tmp/document.pdf", "/private/var/mnt/rootfs-other/file"};
        const char *expected[] = {"/", "/tmp/document.pdf", "/private/var/mnt/rootfs-other/file"};
        for (unsigned i = 0; i < 3; ++i) {
            char path[MAXPATHLEN] = {};
            test_kernel_path = kernel[i];
            ssize_t length = macws_fsgetpath_namespace_compat(path, sizeof(path), NULL, 1);
            CHECK(length == (ssize_t)strlen(expected[i]) + 1 && !strcmp(path, expected[i]));
        }
        puts("chroot namespace contract: PASS");
    }
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="macws-namespace-contract-") as directory:
            path = Path(directory) / "namespace.m"
            binary = Path(directory) / "namespace"
            path.write_text(harness)
            built = subprocess.run([compiler, "-O0", "-Wall", "-Wextra", "-Werror",
                                    "-Wno-unused-function", "-Wno-unused-parameter",
                                    str(path), "-framework", "Foundation", "-o", str(binary)],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("chroot namespace contract: PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
