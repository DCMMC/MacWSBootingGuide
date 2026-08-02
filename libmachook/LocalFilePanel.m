// Keep Ventura's stock NSOpenPanel/NSSavePanel in the client process.
//
// RE-confirmed on macOS 13.4 AppKit from the target rootfs:
// -[NSLocalSavePanel _useRemotePanel] reads the NSUseRemoteSavePanel AppKit
// configuration key and defaults it to true.  When true, +[NSOpenPanel
// openPanel] enters the OpenAndSavePanel/ViewBridge service graph, whose
// auxiliary endpoints cannot be provisioned by iPadOS 16.3 launchservicesd.
//
// AppKit already contains the complete native implementation:
// NSLocalOpenPanel -> NSLocalSavePanel -> NSPanel.  Selecting that supported
// implementation at the factory boundary preserves the public NSOpenPanel
// API, native FinderKit UI, delegate callbacks, modal/sheet behaviour, and
// NSURL results.  There is no surrogate UI and no validation bypass here.

@import Foundation;

#import <objc/message.h>
#import <objc/runtime.h>

#include <stdio.h>
#include <stdlib.h>

static id MacWSRuntimeString(const char *UTF8) {
    Class stringClass = objc_getClass("NSString");
    return stringClass && UTF8
        ? ((id (*)(id, SEL, const char *))objc_msgSend)(
              (id)stringClass, sel_registerName("stringWithUTF8String:"),
              UTF8)
        : nil;
}

__attribute__((constructor))
static void MacWSUseNativeInProcessFilePanels(void) {
    // This preference is meaningful only to AppKit clients.  The old global
    // constructor called +[NSUserDefaults standardUserDefaults] in every
    // injected process, including defaults(1), cfprefsd, and launchservicesd.
    // Runtime-confirmed with LLDB on the target: that constructor reached
    // _CFXPreferences::_copyDaemonConnection... and cached the iPadOS
    // com.apple.cfprefsd.daemon endpoint before libmachook's private-service
    // routing hook was installed.  The later production persistence probe
    // therefore talked to the incompatible iOS daemon and failed.
    //
    // AppKit is already mapped before an AppKit executable's constructors run.
    // Limit the preference to those clients and enqueue it after all dylib
    // constructors have installed their service routing.  This preserves the
    // stock NSLocalOpenPanel selection without initializing CFPreferences in
    // unrelated daemons.
    if (!objc_getClass("NSApplication")) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        Class defaultsClass = objc_getClass("NSUserDefaults");
        id defaults = defaultsClass
            ? ((id (*)(id, SEL))objc_msgSend)(
                  (id)defaultsClass,
                  sel_registerName("standardUserDefaults"))
            : nil;
        id key = MacWSRuntimeString("NSUseRemoteSavePanel");
        if (!defaults || !key) return;
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(
            defaults, sel_registerName("setBool:forKey:"), NO, key);

        if (getenv("MACWS_FILE_PANEL_DIAG")) {
            fprintf(stderr,
                    "MACWS_FILE_PANEL native=AppKit-in-process "
                    "NSUseRemoteSavePanel=0\n");
            fflush(stderr);
        }
    });
}
