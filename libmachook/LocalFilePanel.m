// Functional in-process NSOpenPanel fallback for the stripped macOS rootfs.
//
// Ventura's open panel normally lives in an XPC/ViewBridge view service. The
// target rootfs has no loadable ViewBridge image, so the stock construction
// path aborts before runModal/begin can return. This file provides an ordinary
// AppKit filesystem browser and real NSURL results. It is installed only when
// the standalone ViewBridge image is absent.
//
// Load-bearing arm64e constraint: do not declare a new Objective-C class in
// this on-device-built dylib. Runtime crash bash-2026-08-02-042833.ips shows
// libobjc readClass authenticating the static
// OBJC_CLASS_$_MacWSLocalFilePanelController metadata and trapping with
// pointer-authentication DA before any constructor ran. The on-device lld does
// not emit the address-diversified class_t metadata expected by macOS libobjc.
// Both helper classes below are therefore created with objc_allocateClassPair;
// libobjc owns and signs their metadata at the correct upstream boundary.

@import Foundation;
@import Darwin;

#import <objc/message.h>
#import <objc/runtime.h>

@interface NSObject (MacWSLocalFilePanelAppKitDeclarations)
- (id)initWithContentRect:(CGRect)rect
                styleMask:(NSUInteger)styleMask
                  backing:(NSUInteger)backing
                    defer:(BOOL)defer;
- (id)initWithFrame:(CGRect)frame;
- (id)initWithIdentifier:(id)identifier;
- (void)addSubview:(id)view;
- (id)contentView;
- (void)setTitle:(id)title;
- (void)setStringValue:(id)value;
- (id)stringValue;
- (void)setTarget:(id)target;
- (void)setAction:(SEL)action;
- (void)setKeyEquivalent:(id)value;
- (void)setDoubleAction:(SEL)action;
- (void)setEditable:(BOOL)editable;
- (void)setSelectable:(BOOL)selectable;
- (void)setBezeled:(BOOL)bezeled;
- (void)setDrawsBackground:(BOOL)drawsBackground;
- (void)setHasVerticalScroller:(BOOL)enabled;
- (void)setAutohidesScrollers:(BOOL)enabled;
- (void)setDocumentView:(id)view;
- (void)setHeaderView:(id)view;
- (void)addTableColumn:(id)column;
- (void)setWidth:(CGFloat)width;
- (void)setRowHeight:(CGFloat)height;
- (void)setDelegate:(id)delegate;
- (void)setDataSource:(id)dataSource;
- (void)setAllowsMultipleSelection:(BOOL)enabled;
- (void)reloadData;
- (NSInteger)selectedRow;
- (id)selectedRowIndexes;
- (void)center;
- (void)makeKeyAndOrderFront:(id)sender;
- (void)close;
- (void)setReleasedWhenClosed:(BOOL)releasedWhenClosed;
- (NSInteger)runModalForWindow:(id)window;
- (void)stopModalWithCode:(NSInteger)response;
- (BOOL)canChooseFiles;
- (BOOL)canChooseDirectories;
- (BOOL)allowsMultipleSelection;
- (id)directoryURL;
- (id)message;
- (id)prompt;
@end

static const NSUInteger MacWSWindowStyleTitled = 1u << 0;
static const NSUInteger MacWSWindowStyleClosable = 1u << 1;
static const NSUInteger MacWSWindowStyleResizable = 1u << 3;
static const NSUInteger MacWSBackingStoreBuffered = 2;
static const NSInteger MacWSModalResponseCancel = 0;
static const NSInteger MacWSModalResponseOK = 1;

static const void *MacWSLocalPanelURLsKey = &MacWSLocalPanelURLsKey;
static const void *MacWSControllerSourceKey = &MacWSControllerSourceKey;
static const void *MacWSControllerWindowKey = &MacWSControllerWindowKey;
static const void *MacWSControllerTableKey = &MacWSControllerTableKey;
static const void *MacWSControllerPathKey = &MacWSControllerPathKey;
static const void *MacWSControllerStatusKey = &MacWSControllerStatusKey;
static const void *MacWSControllerDirectoryKey = &MacWSControllerDirectoryKey;
static const void *MacWSControllerEntriesKey = &MacWSControllerEntriesKey;
static const void *MacWSControllerSelectionKey = &MacWSControllerSelectionKey;
static const void *MacWSControllerCanFilesKey = &MacWSControllerCanFilesKey;
static const void *MacWSControllerCanDirectoriesKey =
    &MacWSControllerCanDirectoriesKey;
static const void *MacWSControllerMultipleKey = &MacWSControllerMultipleKey;
static const void *MacWSControllerResponseKey = &MacWSControllerResponseKey;

static const void *MacWSProxyCanFilesKey = &MacWSProxyCanFilesKey;
static const void *MacWSProxyCanDirectoriesKey = &MacWSProxyCanDirectoriesKey;
static const void *MacWSProxyMultipleKey = &MacWSProxyMultipleKey;
static const void *MacWSProxyShowsHiddenKey = &MacWSProxyShowsHiddenKey;
static const void *MacWSProxyDirectoryKey = &MacWSProxyDirectoryKey;
static const void *MacWSProxyMessageKey = &MacWSProxyMessageKey;
static const void *MacWSProxyPromptKey = &MacWSProxyPromptKey;
static const void *MacWSProxyTitleKey = &MacWSProxyTitleKey;
static const void *MacWSProxyAllowedTypesKey = &MacWSProxyAllowedTypesKey;
static const void *MacWSProxyAllowedContentTypesKey =
    &MacWSProxyAllowedContentTypesKey;
static const void *MacWSProxyDelegateKey = &MacWSProxyDelegateKey;
static const void *MacWSProxyAccessoryKey = &MacWSProxyAccessoryKey;

static IMP MacWSOriginalOpenPanelURLs;
static IMP MacWSOriginalOpenPanelURL;
static IMP MacWSOriginalOpenPanelFactory;
static IMP MacWSOriginalOpenPanelRawFactory;
static Class MacWSLocalFilePanelControllerClass;
static Class MacWSLocalOpenPanelProxyClass;

static BOOL MacWSLocalFilePanelDiagnosticsEnabled(void) {
    return getenv("MACWS_FILE_PANEL_DIAG") != NULL ||
        access("/tmp/macws_file_panel_diag", F_OK) == 0;
}

static CGRect MacWSFilePanelRect(CGFloat x, CGFloat y, CGFloat width,
                                 CGFloat height) {
    return (CGRect){{x, y}, {width, height}};
}

static BOOL MacWSURLIsDirectory(NSURL *URL) {
    NSNumber *directory = nil;
    return URL && [URL getResourceValue:&directory
                                  forKey:NSURLIsDirectoryKey error:nil] &&
        directory.boolValue;
}

// Objective-C constant strings in an on-device arm64e image carry the same
// incompatible static isa representation as static class metadata. The first
// runtime-class smoke test reached this next invariant and crashed in NSLog's
// _fastCStringContents: with __CFConstantStringClassReference carrying a bad
// authenticated pointer (bash-2026-08-02-043543.ips). Construct every local
// string through the already-realized NSString class instead.
static NSString *MacWSRuntimeString(const char *UTF8) {
    Class stringClass = objc_getClass("NSString");
    if (!stringClass || !UTF8) return nil;
    return ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)stringClass, sel_registerName("stringWithUTF8String:"), UTF8);
}

static id MacWSAssociated(id object, const void *key) {
    return object ? objc_getAssociatedObject(object, key) : nil;
}

static void MacWSSetAssociated(id object, const void *key, id value) {
    if (object) objc_setAssociatedObject(object, key, value,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL MacWSAssociatedBool(id object, const void *key,
                                BOOL fallback) {
    NSNumber *number = MacWSAssociated(object, key);
    return number ? number.boolValue : fallback;
}

static void MacWSSetAssociatedBool(id object, const void *key, BOOL value) {
    MacWSSetAssociated(object, key, @(value));
}

static NSInteger MacWSAssociatedInteger(id object, const void *key,
                                        NSInteger fallback) {
    NSNumber *number = MacWSAssociated(object, key);
    return number ? number.integerValue : fallback;
}

static void MacWSSetAssociatedInteger(id object, const void *key,
                                      NSInteger value) {
    MacWSSetAssociated(object, key, @(value));
}

static id MacWSControllerMakeLabel(CGRect frame, NSString *value) {
    Class labelClass = objc_getClass("NSTextField");
    id label = [[labelClass alloc] initWithFrame:frame];
    [label setStringValue:value ?: MacWSRuntimeString("")];
    [label setEditable:NO];
    [label setSelectable:YES];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    return [label autorelease];
}

static id MacWSControllerMakeButton(id controller, CGRect frame,
                                    NSString *title, SEL action) {
    Class buttonClass = objc_getClass("NSButton");
    id button = [[buttonClass alloc] initWithFrame:frame];
    [button setTitle:title];
    [button setTarget:controller];
    [button setAction:action];
    return [button autorelease];
}

static void MacWSControllerSetStatus(id self, NSString *status) {
    [MacWSAssociated(self, MacWSControllerStatusKey)
        setStringValue:status ?: MacWSRuntimeString("")];
}

static void MacWSControllerReloadDirectory(id self, NSURL *directory) {
    if (!MacWSURLIsDirectory(directory)) {
        MacWSControllerSetStatus(self,
            MacWSRuntimeString("这个路径不是文件夹"));
        return;
    }
    NSError *error = nil;
    NSArray *keys = [NSArray arrayWithObjects:NSURLIsDirectoryKey,
        NSURLIsHiddenKey, NSURLLocalizedNameKey, nil];
    NSArray *contents = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:directory
       includingPropertiesForKeys:keys options:0 error:&error];
    if (!contents) {
        MacWSControllerSetStatus(self,
            error.localizedDescription ?: MacWSRuntimeString("无法读取此文件夹"));
        return;
    }
    contents = [contents sortedArrayUsingComparator:
        ^NSComparisonResult(NSURL *left, NSURL *right) {
            BOOL leftDirectory = MacWSURLIsDirectory(left);
            BOOL rightDirectory = MacWSURLIsDirectory(right);
            if (leftDirectory != rightDirectory)
                return leftDirectory ? NSOrderedAscending : NSOrderedDescending;
            return [(left.lastPathComponent ?: MacWSRuntimeString(""))
                localizedStandardCompare:(right.lastPathComponent ?:
                    MacWSRuntimeString(""))];
        }];
    MacWSSetAssociated(self, MacWSControllerDirectoryKey, directory);
    MacWSSetAssociated(self, MacWSControllerEntriesKey, contents);
    [MacWSAssociated(self, MacWSControllerPathKey)
        setStringValue:directory.path ?: MacWSRuntimeString("/")];
    [MacWSAssociated(self, MacWSControllerTableKey) reloadData];
    MacWSControllerSetStatus(self, [NSString stringWithFormat:
        MacWSRuntimeString("%lu 项目"),
        (unsigned long)contents.count]);
}

static void MacWSControllerBuildWindow(id self) {
    CGRect frame = MacWSFilePanelRect(0, 0, 760, 540);
    Class panelClass = objc_getClass("NSPanel");
    id window = [[panelClass alloc] initWithContentRect:frame
        styleMask:(MacWSWindowStyleTitled | MacWSWindowStyleClosable |
                   MacWSWindowStyleResizable)
        backing:MacWSBackingStoreBuffered defer:NO];
    MacWSSetAssociated(self, MacWSControllerWindowKey, window);
    [window release];
    [window setReleasedWhenClosed:NO];
    [window setTitle:MacWSRuntimeString("打开文件")];
    [window setDelegate:self];
    id content = [window contentView];
    id source = MacWSAssociated(self, MacWSControllerSourceKey);

    NSString *message = [source message];
    if (!message.length) message = MacWSRuntimeString("选择文件或文件夹");
    [content addSubview:MacWSControllerMakeLabel(
        MacWSFilePanelRect(18, 506, 724, 22), message)];
    [content addSubview:MacWSControllerMakeButton(self,
        MacWSFilePanelRect(18, 466, 70, 30), MacWSRuntimeString("返回"),
        sel_registerName("back:"))];
    [content addSubview:MacWSControllerMakeButton(self,
        MacWSFilePanelRect(94, 466, 70, 30), MacWSRuntimeString("主目录"),
        sel_registerName("home:"))];

    Class textFieldClass = objc_getClass("NSTextField");
    id path = [[textFieldClass alloc] initWithFrame:
        MacWSFilePanelRect(172, 467, 570, 28)];
    [path setTarget:self];
    [path setAction:sel_registerName("pathEntered:")];
    [content addSubview:path];
    MacWSSetAssociated(self, MacWSControllerPathKey, path);
    [path release];

    Class scrollClass = objc_getClass("NSScrollView");
    id scroll = [[scrollClass alloc] initWithFrame:
        MacWSFilePanelRect(18, 72, 724, 384)];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutohidesScrollers:YES];

    Class tableClass = objc_getClass("NSTableView");
    id table = [[tableClass alloc] initWithFrame:
        MacWSFilePanelRect(0, 0, 724, 384)];
    Class columnClass = objc_getClass("NSTableColumn");
    id column = [[columnClass alloc]
        initWithIdentifier:MacWSRuntimeString("name")];
    [column setWidth:710];
    [table addTableColumn:column];
    [column release];
    [table setHeaderView:nil];
    [table setRowHeight:26];
    [table setDelegate:self];
    [table setDataSource:self];
    [table setAllowsMultipleSelection:MacWSAssociatedBool(
        self, MacWSControllerMultipleKey, NO)];
    [table setTarget:self];
    [table setDoubleAction:sel_registerName("doubleClick:")];
    [scroll setDocumentView:table];
    MacWSSetAssociated(self, MacWSControllerTableKey, table);
    [table release];
    [content addSubview:scroll];
    [scroll release];

    id status = MacWSControllerMakeLabel(
        MacWSFilePanelRect(18, 23, 470, 28), MacWSRuntimeString(""));
    MacWSSetAssociated(self, MacWSControllerStatusKey, status);
    [content addSubview:status];
    id cancel = MacWSControllerMakeButton(self,
        MacWSFilePanelRect(570, 18, 80, 34), MacWSRuntimeString("取消"),
        sel_registerName("cancel:"));
    [cancel setKeyEquivalent:MacWSRuntimeString("\e")];
    [content addSubview:cancel];
    NSString *prompt = [source prompt];
    if (!prompt.length) prompt = MacWSRuntimeString("打开");
    id open = MacWSControllerMakeButton(self,
        MacWSFilePanelRect(658, 18, 84, 34), prompt,
        sel_registerName("confirm:"));
    [open setKeyEquivalent:MacWSRuntimeString("\r")];
    [content addSubview:open];
    MacWSControllerReloadDirectory(self,
        MacWSAssociated(self, MacWSControllerDirectoryKey));
    [window center];
}

static NSInteger MacWSControllerRowCount(id self, SEL selector, id table) {
    (void)selector;
    (void)table;
    return (NSInteger)[MacWSAssociated(self, MacWSControllerEntriesKey) count];
}

static id MacWSControllerCellValue(id self, SEL selector, id table, id column,
                                   NSInteger row) {
    (void)selector;
    (void)table;
    (void)column;
    NSArray *entries = MacWSAssociated(self, MacWSControllerEntriesKey);
    if (row < 0 || (NSUInteger)row >= entries.count)
        return MacWSRuntimeString("");
    NSURL *URL = entries[(NSUInteger)row];
    NSString *prefix = MacWSURLIsDirectory(URL)
        ? MacWSRuntimeString("▸  ") : MacWSRuntimeString("   ");
    return [prefix stringByAppendingString:URL.lastPathComponent ?:
        MacWSRuntimeString("")];
}

static NSArray *MacWSControllerSelectedEntries(id self) {
    NSMutableArray *selected = [NSMutableArray array];
    id table = MacWSAssociated(self, MacWSControllerTableKey);
    NSArray *entries = MacWSAssociated(self, MacWSControllerEntriesKey);
    NSIndexSet *indexes = [table selectedRowIndexes];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        (void)stop;
        if (index < entries.count) [selected addObject:entries[index]];
    }];
    return selected;
}

static void MacWSControllerFinish(id self, NSArray *URLs) {
    MacWSSetAssociated(self, MacWSControllerSelectionKey, URLs);
    MacWSSetAssociatedInteger(self, MacWSControllerResponseKey,
                              MacWSModalResponseOK);
    id application = ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSApplication"),
        sel_registerName("sharedApplication"));
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(application,
        sel_registerName("stopModalWithCode:"), MacWSModalResponseOK);
    [MacWSAssociated(self, MacWSControllerWindowKey) close];
}

static void MacWSControllerConfirm(id self, SEL selector, id sender) {
    (void)selector;
    (void)sender;
    NSArray *selection = MacWSControllerSelectedEntries(self);
    NSMutableArray *accepted = [NSMutableArray array];
    BOOL chooseFiles = MacWSAssociatedBool(
        self, MacWSControllerCanFilesKey, YES);
    BOOL chooseDirectories = MacWSAssociatedBool(
        self, MacWSControllerCanDirectoriesKey, NO);
    BOOL multiple = MacWSAssociatedBool(
        self, MacWSControllerMultipleKey, NO);
    for (NSURL *URL in selection) {
        BOOL directory = MacWSURLIsDirectory(URL);
        if ((directory && chooseDirectories) || (!directory && chooseFiles))
            [accepted addObject:URL];
        if (!multiple && accepted.count) break;
    }
    if (!accepted.count && chooseDirectories && !selection.count) {
        NSURL *directory = MacWSAssociated(
            self, MacWSControllerDirectoryKey);
        if (directory) [accepted addObject:directory];
    }
    if (!accepted.count) {
        MacWSControllerSetStatus(self, chooseDirectories
            ? MacWSRuntimeString("请选择一个可打开的项目")
            : MacWSRuntimeString("请选择一个文件"));
        return;
    }
    MacWSControllerFinish(self, accepted);
}

static void MacWSControllerDoubleClick(id self, SEL selector, id sender) {
    (void)selector;
    (void)sender;
    id table = MacWSAssociated(self, MacWSControllerTableKey);
    NSArray *entries = MacWSAssociated(self, MacWSControllerEntriesKey);
    NSInteger row = [table selectedRow];
    if (row < 0 || (NSUInteger)row >= entries.count) return;
    NSURL *URL = entries[(NSUInteger)row];
    if (MacWSURLIsDirectory(URL)) MacWSControllerReloadDirectory(self, URL);
    else if (MacWSAssociatedBool(self, MacWSControllerCanFilesKey, YES))
        MacWSControllerFinish(self, [NSArray arrayWithObject:URL]);
}

static void MacWSControllerPathEntered(id self, SEL selector, id sender) {
    (void)selector;
    NSString *path = [[sender stringValue] stringByExpandingTildeInPath];
    NSURL *URL = [NSURL fileURLWithPath:path ?: MacWSRuntimeString("")];
    if (MacWSURLIsDirectory(URL)) MacWSControllerReloadDirectory(self, URL);
    else if ([[NSFileManager defaultManager] fileExistsAtPath:URL.path] &&
             MacWSAssociatedBool(self, MacWSControllerCanFilesKey, YES))
        MacWSControllerFinish(self, [NSArray arrayWithObject:URL]);
    else MacWSControllerSetStatus(self,
        MacWSRuntimeString("路径不存在或不可打开"));
}

static void MacWSControllerBack(id self, SEL selector, id sender) {
    (void)selector;
    (void)sender;
    NSURL *parent = [MacWSAssociated(self, MacWSControllerDirectoryKey)
        URLByDeletingLastPathComponent];
    if (parent.path.length) MacWSControllerReloadDirectory(self, parent);
}

static void MacWSControllerHome(id self, SEL selector, id sender) {
    (void)selector;
    (void)sender;
    NSURL *home = [NSURL fileURLWithPath:MacWSRuntimeString("/Users/root")
                            isDirectory:YES];
    MacWSControllerReloadDirectory(self, MacWSURLIsDirectory(home) ? home :
        [NSURL fileURLWithPath:MacWSRuntimeString("/") isDirectory:YES]);
}

static void MacWSControllerCancel(id self, SEL selector, id sender) {
    (void)selector;
    (void)sender;
    MacWSSetAssociatedInteger(self, MacWSControllerResponseKey,
                              MacWSModalResponseCancel);
    id application = ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSApplication"),
        sel_registerName("sharedApplication"));
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(application,
        sel_registerName("stopModalWithCode:"), MacWSModalResponseCancel);
    [MacWSAssociated(self, MacWSControllerWindowKey) close];
}

static BOOL MacWSControllerWindowShouldClose(id self, SEL selector,
                                             id sender) {
    MacWSControllerCancel(self, selector, sender);
    return YES;
}

static NSInteger MacWSControllerRun(id self, SEL selector) {
    (void)selector;
    MacWSControllerBuildWindow(self);
    id window = MacWSAssociated(self, MacWSControllerWindowKey);
    [window makeKeyAndOrderFront:nil];
    id application = ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSApplication"),
        sel_registerName("sharedApplication"));
    ((NSInteger (*)(id, SEL, id))objc_msgSend)(application,
        sel_registerName("runModalForWindow:"), window);
    NSInteger response = MacWSAssociatedInteger(
        self, MacWSControllerResponseKey, MacWSModalResponseCancel);
    NSArray *URLs = MacWSAssociated(self, MacWSControllerSelectionKey);
    if (response == MacWSModalResponseOK && URLs.count) {
        objc_setAssociatedObject(
            MacWSAssociated(self, MacWSControllerSourceKey),
            MacWSLocalPanelURLsKey, URLs,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return response;
}

static id MacWSCreateController(id panel) {
    if (!MacWSLocalFilePanelControllerClass) return nil;
    id controller = ((id (*)(id, SEL))objc_msgSend)(
        (id)MacWSLocalFilePanelControllerClass, sel_registerName("new"));
    if (!controller) return nil;
    MacWSSetAssociated(controller, MacWSControllerSourceKey, panel);
    MacWSSetAssociatedBool(controller, MacWSControllerCanFilesKey,
        [panel canChooseFiles]);
    MacWSSetAssociatedBool(controller, MacWSControllerCanDirectoriesKey,
        [panel canChooseDirectories]);
    MacWSSetAssociatedBool(controller, MacWSControllerMultipleKey,
        [panel allowsMultipleSelection]);
    NSURL *requested = [panel directoryURL];
    if (!MacWSURLIsDirectory(requested))
        requested = [NSURL fileURLWithPath:MacWSRuntimeString("/Users/root")
                               isDirectory:YES];
    if (!MacWSURLIsDirectory(requested))
        requested = [NSURL fileURLWithPath:MacWSRuntimeString("/")
                               isDirectory:YES];
    MacWSSetAssociated(controller, MacWSControllerDirectoryKey, requested);
    MacWSSetAssociatedInteger(controller, MacWSControllerResponseKey,
                              MacWSModalResponseCancel);
    return controller;
}

static BOOL MacWSProxyIsKindOfClass(id self, SEL selector, Class candidate) {
    Class openPanel = objc_getClass("NSOpenPanel");
    Class savePanel = objc_getClass("NSSavePanel");
    if (candidate == openPanel || candidate == savePanel) return YES;
    IMP original = class_getMethodImplementation(
        objc_getClass("NSObject"), selector);
    return original
        ? ((BOOL (*)(id, SEL, Class))original)(self, selector, candidate)
        : NO;
}

#define MACWS_PROXY_BOOL_GETTER(name, key, fallback) \
    static BOOL name(id self, SEL selector) { \
        (void)selector; \
        return MacWSAssociatedBool(self, key, fallback); \
    }
#define MACWS_PROXY_BOOL_SETTER(name, key) \
    static void name(id self, SEL selector, BOOL value) { \
        (void)selector; \
        MacWSSetAssociatedBool(self, key, value); \
    }
#define MACWS_PROXY_OBJECT_GETTER(name, key) \
    static id name(id self, SEL selector) { \
        (void)selector; \
        return MacWSAssociated(self, key); \
    }
#define MACWS_PROXY_OBJECT_SETTER(name, key) \
    static void name(id self, SEL selector, id value) { \
        (void)selector; \
        MacWSSetAssociated(self, key, value); \
    }

MACWS_PROXY_BOOL_GETTER(MacWSProxyCanChooseFiles,
                        MacWSProxyCanFilesKey, YES)
MACWS_PROXY_BOOL_SETTER(MacWSProxySetCanChooseFiles,
                        MacWSProxyCanFilesKey)
MACWS_PROXY_BOOL_GETTER(MacWSProxyCanChooseDirectories,
                        MacWSProxyCanDirectoriesKey, NO)
MACWS_PROXY_BOOL_SETTER(MacWSProxySetCanChooseDirectories,
                        MacWSProxyCanDirectoriesKey)
MACWS_PROXY_BOOL_GETTER(MacWSProxyAllowsMultipleSelection,
                        MacWSProxyMultipleKey, NO)
MACWS_PROXY_BOOL_SETTER(MacWSProxySetAllowsMultipleSelection,
                        MacWSProxyMultipleKey)
MACWS_PROXY_BOOL_GETTER(MacWSProxyShowsHiddenFiles,
                        MacWSProxyShowsHiddenKey, NO)
MACWS_PROXY_BOOL_SETTER(MacWSProxySetShowsHiddenFiles,
                        MacWSProxyShowsHiddenKey)
MACWS_PROXY_OBJECT_GETTER(MacWSProxyDirectoryURL, MacWSProxyDirectoryKey)
MACWS_PROXY_OBJECT_SETTER(MacWSProxySetDirectoryURL, MacWSProxyDirectoryKey)
MACWS_PROXY_OBJECT_GETTER(MacWSProxyMessage, MacWSProxyMessageKey)
MACWS_PROXY_OBJECT_SETTER(MacWSProxySetMessage, MacWSProxyMessageKey)
MACWS_PROXY_OBJECT_GETTER(MacWSProxyPrompt, MacWSProxyPromptKey)
MACWS_PROXY_OBJECT_SETTER(MacWSProxySetPrompt, MacWSProxyPromptKey)
MACWS_PROXY_OBJECT_GETTER(MacWSProxyTitle, MacWSProxyTitleKey)
MACWS_PROXY_OBJECT_SETTER(MacWSProxySetTitle, MacWSProxyTitleKey)
MACWS_PROXY_OBJECT_GETTER(MacWSProxyAllowedFileTypes,
                          MacWSProxyAllowedTypesKey)
MACWS_PROXY_OBJECT_SETTER(MacWSProxySetAllowedFileTypes,
                          MacWSProxyAllowedTypesKey)
MACWS_PROXY_OBJECT_GETTER(MacWSProxyAllowedContentTypes,
                          MacWSProxyAllowedContentTypesKey)
MACWS_PROXY_OBJECT_SETTER(MacWSProxySetAllowedContentTypes,
                          MacWSProxyAllowedContentTypesKey)
MACWS_PROXY_OBJECT_GETTER(MacWSProxyDelegate, MacWSProxyDelegateKey)
MACWS_PROXY_OBJECT_GETTER(MacWSProxyAccessoryView, MacWSProxyAccessoryKey)
MACWS_PROXY_OBJECT_SETTER(MacWSProxySetAccessoryView,
                          MacWSProxyAccessoryKey)

static void MacWSProxySetDelegate(id self, SEL selector, id value) {
    (void)selector;
    objc_setAssociatedObject(self, MacWSProxyDelegateKey, value,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void MacWSProxyIgnoreBool(id self, SEL selector, BOOL value) {
    (void)self;
    (void)selector;
    (void)value;
}

static void MacWSProxyIgnoreObject(id self, SEL selector, id value) {
    (void)self;
    (void)selector;
    (void)value;
}

static void MacWSProxyIgnoreInteger(id self, SEL selector, NSInteger value) {
    (void)self;
    (void)selector;
    (void)value;
}

static id MacWSProxyURLs(id self, SEL selector) {
    (void)selector;
    return MacWSAssociated(self, MacWSLocalPanelURLsKey) ?: [NSArray array];
}

static id MacWSProxyURL(id self, SEL selector) {
    return [MacWSProxyURLs(self, selector) firstObject];
}

static id MacWSProxyFilenames(id self, SEL selector) {
    return [MacWSProxyURLs(self, selector)
        valueForKey:MacWSRuntimeString("path")];
}

static NSInteger MacWSProxyRunModal(id self, SEL selector) {
    (void)selector;
    id controller = MacWSCreateController(self);
    if (!controller) return MacWSModalResponseCancel;
    NSInteger response = MacWSControllerRun(
        controller, sel_registerName("run"));
    [controller release];
    return response;
}

static NSInteger MacWSProxyRunModalDirectoryFileTypes(
        id self, SEL selector, NSString *path, NSString *name,
        NSArray *types) {
    (void)selector;
    (void)name;
    if (path.length) {
        NSURL *directory = [NSURL fileURLWithPath:
            [path stringByExpandingTildeInPath] isDirectory:YES];
        if (MacWSURLIsDirectory(directory))
            MacWSSetAssociated(self, MacWSProxyDirectoryKey, directory);
    }
    if (types) MacWSSetAssociated(self, MacWSProxyAllowedTypesKey, types);
    return MacWSProxyRunModal(self, sel_registerName("runModal"));
}

static NSInteger MacWSProxyRunModalDirectoryFile(
        id self, SEL selector, NSString *path, NSString *name) {
    return MacWSProxyRunModalDirectoryFileTypes(
        self, selector, path, name, nil);
}

static NSInteger MacWSProxyRunModalTypes(id self, SEL selector,
                                         NSArray *types) {
    return MacWSProxyRunModalDirectoryFileTypes(
        self, selector, nil, nil, types);
}

static void MacWSProxyBegin(id self, SEL selector,
                            void (^completion)(NSInteger)) {
    (void)selector;
    void (^retainedCompletion)(NSInteger) = [completion copy];
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger response = MacWSProxyRunModal(
            self, sel_registerName("runModal"));
        if (retainedCompletion) retainedCompletion(response);
        [retainedCompletion release];
        [self release];
    });
}

static void MacWSProxyBeginSheet(id self, SEL selector, id parent,
                                 void (^completion)(NSInteger)) {
    (void)selector;
    (void)parent;
    MacWSProxyBegin(self, sel_registerName("beginWithCompletionHandler:"),
                    completion);
}

static BOOL MacWSAddMethod(Class cls, const char *name, IMP implementation,
                           const char *types) {
    return class_addMethod(cls, sel_registerName(name), implementation, types);
}

static BOOL MacWSRegisterLocalFilePanelClasses(void) {
    static BOOL attempted;
    if (attempted) return MacWSLocalFilePanelControllerClass &&
        MacWSLocalOpenPanelProxyClass;
    attempted = YES;
    Class root = objc_getClass("NSObject");
    if (!root) return NO;

    Class controller = objc_allocateClassPair(
        root, "MacWSLocalFilePanelController", 0);
    if (!controller) controller = objc_getClass(
        "MacWSLocalFilePanelController");
    if (!controller) return NO;
    if (!objc_getClass("MacWSLocalFilePanelController")) {
        BOOL methods = YES;
        methods &= MacWSAddMethod(controller, "run",
            (IMP)MacWSControllerRun, "q@:");
        methods &= MacWSAddMethod(controller, "numberOfRowsInTableView:",
            (IMP)MacWSControllerRowCount, "q@:@");
        methods &= MacWSAddMethod(controller,
            "tableView:objectValueForTableColumn:row:",
            (IMP)MacWSControllerCellValue, "@@:@@q");
        methods &= MacWSAddMethod(controller, "confirm:",
            (IMP)MacWSControllerConfirm, "v@:@");
        methods &= MacWSAddMethod(controller, "doubleClick:",
            (IMP)MacWSControllerDoubleClick, "v@:@");
        methods &= MacWSAddMethod(controller, "pathEntered:",
            (IMP)MacWSControllerPathEntered, "v@:@");
        methods &= MacWSAddMethod(controller, "back:",
            (IMP)MacWSControllerBack, "v@:@");
        methods &= MacWSAddMethod(controller, "home:",
            (IMP)MacWSControllerHome, "v@:@");
        methods &= MacWSAddMethod(controller, "cancel:",
            (IMP)MacWSControllerCancel, "v@:@");
        methods &= MacWSAddMethod(controller, "windowShouldClose:",
            (IMP)MacWSControllerWindowShouldClose, "B@:@");
        if (!methods) {
            objc_disposeClassPair(controller);
            return NO;
        }
        objc_registerClassPair(controller);
    }
    MacWSLocalFilePanelControllerClass = controller;

    Class proxy = objc_allocateClassPair(root, "MacWSLocalOpenPanelProxy", 0);
    if (!proxy) proxy = objc_getClass("MacWSLocalOpenPanelProxy");
    if (!proxy) return NO;
    if (!objc_getClass("MacWSLocalOpenPanelProxy")) {
        BOOL methods = YES;
        methods &= MacWSAddMethod(proxy, "isKindOfClass:",
            (IMP)MacWSProxyIsKindOfClass, "B@:#");
        methods &= MacWSAddMethod(proxy, "canChooseFiles",
            (IMP)MacWSProxyCanChooseFiles, "B@:");
        methods &= MacWSAddMethod(proxy, "setCanChooseFiles:",
            (IMP)MacWSProxySetCanChooseFiles, "v@:B");
        methods &= MacWSAddMethod(proxy, "canChooseDirectories",
            (IMP)MacWSProxyCanChooseDirectories, "B@:");
        methods &= MacWSAddMethod(proxy, "setCanChooseDirectories:",
            (IMP)MacWSProxySetCanChooseDirectories, "v@:B");
        methods &= MacWSAddMethod(proxy, "allowsMultipleSelection",
            (IMP)MacWSProxyAllowsMultipleSelection, "B@:");
        methods &= MacWSAddMethod(proxy, "setAllowsMultipleSelection:",
            (IMP)MacWSProxySetAllowsMultipleSelection, "v@:B");
        methods &= MacWSAddMethod(proxy, "showsHiddenFiles",
            (IMP)MacWSProxyShowsHiddenFiles, "B@:");
        methods &= MacWSAddMethod(proxy, "setShowsHiddenFiles:",
            (IMP)MacWSProxySetShowsHiddenFiles, "v@:B");
        const struct { const char *get; const char *set; IMP getter; IMP setter; }
            objectProperties[] = {
                {"directoryURL", "setDirectoryURL:",
                 (IMP)MacWSProxyDirectoryURL, (IMP)MacWSProxySetDirectoryURL},
                {"message", "setMessage:",
                 (IMP)MacWSProxyMessage, (IMP)MacWSProxySetMessage},
                {"prompt", "setPrompt:",
                 (IMP)MacWSProxyPrompt, (IMP)MacWSProxySetPrompt},
                {"title", "setTitle:",
                 (IMP)MacWSProxyTitle, (IMP)MacWSProxySetTitle},
                {"allowedFileTypes", "setAllowedFileTypes:",
                 (IMP)MacWSProxyAllowedFileTypes,
                 (IMP)MacWSProxySetAllowedFileTypes},
                {"allowedContentTypes", "setAllowedContentTypes:",
                 (IMP)MacWSProxyAllowedContentTypes,
                 (IMP)MacWSProxySetAllowedContentTypes},
                {"delegate", "setDelegate:",
                 (IMP)MacWSProxyDelegate, (IMP)MacWSProxySetDelegate},
                {"accessoryView", "setAccessoryView:",
                 (IMP)MacWSProxyAccessoryView,
                 (IMP)MacWSProxySetAccessoryView},
            };
        for (NSUInteger index = 0;
             index < sizeof(objectProperties) / sizeof(objectProperties[0]);
             index++) {
            methods &= MacWSAddMethod(proxy, objectProperties[index].get,
                objectProperties[index].getter, "@@:");
            methods &= MacWSAddMethod(proxy, objectProperties[index].set,
                objectProperties[index].setter, "v@:@");
        }
        const char *ignoredBools[] = {
            "setResolvesAliases:", "setTreatsFilePackagesAsDirectories:",
            "setCanCreateDirectories:", "setAllowsOtherFileTypes:",
            "setExtensionHidden:", "setShowsTagField:",
        };
        for (NSUInteger index = 0;
             index < sizeof(ignoredBools) / sizeof(ignoredBools[0]); index++)
            methods &= MacWSAddMethod(proxy, ignoredBools[index],
                (IMP)MacWSProxyIgnoreBool, "v@:B");
        methods &= MacWSAddMethod(proxy, "setNameFieldStringValue:",
            (IMP)MacWSProxyIgnoreObject, "v@:@");
        methods &= MacWSAddMethod(proxy, "setLevel:",
            (IMP)MacWSProxyIgnoreInteger, "v@:q");
        methods &= MacWSAddMethod(proxy, "URLs",
            (IMP)MacWSProxyURLs, "@@:");
        methods &= MacWSAddMethod(proxy, "URL",
            (IMP)MacWSProxyURL, "@@:");
        methods &= MacWSAddMethod(proxy, "filenames",
            (IMP)MacWSProxyFilenames, "@@:");
        methods &= MacWSAddMethod(proxy, "runModal",
            (IMP)MacWSProxyRunModal, "q@:");
        methods &= MacWSAddMethod(proxy,
            "runModalForDirectory:file:types:",
            (IMP)MacWSProxyRunModalDirectoryFileTypes, "q@:@@@");
        methods &= MacWSAddMethod(proxy, "runModalForDirectory:file:",
            (IMP)MacWSProxyRunModalDirectoryFile, "q@:@@");
        methods &= MacWSAddMethod(proxy, "runModalForTypes:",
            (IMP)MacWSProxyRunModalTypes, "q@:@");
        methods &= MacWSAddMethod(proxy, "beginWithCompletionHandler:",
            (IMP)MacWSProxyBegin, "v@:@?");
        methods &= MacWSAddMethod(proxy,
            "beginSheetModalForWindow:completionHandler:",
            (IMP)MacWSProxyBeginSheet, "v@:@@?");
        if (!methods) {
            objc_disposeClassPair(proxy);
            return NO;
        }
        objc_registerClassPair(proxy);
    }
    MacWSLocalOpenPanelProxyClass = proxy;
    return YES;
}

static NSInteger MacWSLocalOpenPanelRunModal(id panel, SEL selector) {
    (void)selector;
    __block NSInteger response = MacWSModalResponseCancel;
    void (^work)(void) = ^{
        id controller = MacWSCreateController(panel);
        if (!controller) return;
        response = MacWSControllerRun(controller, sel_registerName("run"));
        [controller release];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return response;
}

static void MacWSLocalOpenPanelBegin(id panel, SEL selector,
                                    void (^completion)(NSInteger)) {
    (void)selector;
    void (^retainedCompletion)(NSInteger) = [completion copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger response = MacWSLocalOpenPanelRunModal(
            panel, sel_registerName("runModal"));
        if (retainedCompletion) retainedCompletion(response);
        [retainedCompletion release];
    });
}

static void MacWSLocalOpenPanelBeginSheet(id panel, SEL selector, id parent,
                                         void (^completion)(NSInteger)) {
    (void)selector;
    (void)parent;
    MacWSLocalOpenPanelBegin(panel,
        sel_registerName("beginWithCompletionHandler:"), completion);
}

static id MacWSLocalOpenPanelURLs(id panel, SEL selector) {
    NSArray *URLs = objc_getAssociatedObject(panel, MacWSLocalPanelURLsKey);
    if (URLs) return URLs;
    return MacWSOriginalOpenPanelURLs
        ? ((id (*)(id, SEL))MacWSOriginalOpenPanelURLs)(panel, selector)
        : [NSArray array];
}

static id MacWSLocalOpenPanelURL(id panel, SEL selector) {
    NSArray *URLs = objc_getAssociatedObject(panel, MacWSLocalPanelURLsKey);
    if (URLs) return URLs.firstObject;
    return MacWSOriginalOpenPanelURL
        ? ((id (*)(id, SEL))MacWSOriginalOpenPanelURL)(panel, selector)
        : nil;
}

static BOOL MacWSInstallMethodOverride(Class cls, SEL selector, IMP replacement,
                                       IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    if (original) *original = method_getImplementation(method);
    const char *encoding = method_getTypeEncoding(method);
    if (class_addMethod(cls, selector, replacement, encoding)) return YES;
    method = class_getInstanceMethod(cls, selector);
    method_setImplementation(method, replacement);
    return YES;
}

static id MacWSLocalOpenPanelFactory(id cls, SEL selector) {
    if (MacWSLocalFilePanelDiagnosticsEnabled()) {
        fprintf(stderr, "MACWS_FILE_PANEL factory class=%s selector=%s\n",
                class_getName(cls), sel_getName(selector));
        fflush(stderr);
    }
    (void)cls;
    (void)selector;
    if (!MacWSRegisterLocalFilePanelClasses()) return nil;
    id proxy = ((id (*)(id, SEL))objc_msgSend)(
        (id)MacWSLocalOpenPanelProxyClass, sel_registerName("new"));
    MacWSSetAssociatedBool(proxy, MacWSProxyCanFilesKey, YES);
    MacWSSetAssociatedBool(proxy, MacWSProxyCanDirectoriesKey, NO);
    MacWSSetAssociatedBool(proxy, MacWSProxyMultipleKey, NO);
    return [proxy autorelease];
}

static BOOL MacWSInstallClassMethodOverride(Class cls, SEL selector,
                                            IMP replacement, IMP *original) {
    Method method = class_getClassMethod(cls, selector);
    if (!method) return NO;
    if (original) *original = method_getImplementation(method);
    Class metaclass = object_getClass(cls);
    const char *encoding = method_getTypeEncoding(method);
    if (class_addMethod(metaclass, selector, replacement, encoding)) return YES;
    method = class_getClassMethod(cls, selector);
    method_setImplementation(method, replacement);
    return YES;
}

static void MacWSInstallLocalFilePanelIfNeeded(unsigned attempt) {
    static BOOL installed;
    if (installed) return;
    if (access("/System/Library/PrivateFrameworks/ViewBridge.framework/"
               "Versions/A/ViewBridge", F_OK) == 0) return;
    if (!MacWSRegisterLocalFilePanelClasses()) return;
    Class openPanel = objc_getClass("NSOpenPanel");
    if (!openPanel) {
        if (attempt < 39) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    MacWSInstallLocalFilePanelIfNeeded(attempt + 1);
                });
        }
        return;
    }
    // LLDB runtime-confirmed on Terminal PID 134 (2026-08-02): failure enters
    // +[NSSavePanel _crunchyRawUnbonedPanel] -> _initBridgeAndStuff before a
    // modal presentation method. Replace both construction boundaries; keep
    // instance overrides for a panel obtained before installation.
    BOOL factory = MacWSInstallClassMethodOverride(openPanel,
        sel_registerName("openPanel"), (IMP)MacWSLocalOpenPanelFactory,
        &MacWSOriginalOpenPanelFactory);
    BOOL rawFactory = MacWSInstallClassMethodOverride(openPanel,
        sel_registerName("_crunchyRawUnbonedPanel"),
        (IMP)MacWSLocalOpenPanelFactory, &MacWSOriginalOpenPanelRawFactory);
    BOOL run = MacWSInstallMethodOverride(openPanel,
        sel_registerName("runModal"), (IMP)MacWSLocalOpenPanelRunModal, NULL);
    BOOL begin = MacWSInstallMethodOverride(openPanel,
        sel_registerName("beginWithCompletionHandler:"),
        (IMP)MacWSLocalOpenPanelBegin, NULL);
    BOOL sheet = MacWSInstallMethodOverride(openPanel,
        sel_registerName("beginSheetModalForWindow:completionHandler:"),
        (IMP)MacWSLocalOpenPanelBeginSheet, NULL);
    BOOL URLs = MacWSInstallMethodOverride(openPanel,
        sel_registerName("URLs"), (IMP)MacWSLocalOpenPanelURLs,
        &MacWSOriginalOpenPanelURLs);
    BOOL URL = MacWSInstallMethodOverride(openPanel,
        sel_registerName("URL"), (IMP)MacWSLocalOpenPanelURL,
        &MacWSOriginalOpenPanelURL);
    installed = factory && rawFactory && run && begin && sheet && URLs && URL;
    if (MacWSLocalFilePanelDiagnosticsEnabled()) {
        fprintf(stderr, "MACWS_FILE_PANEL install attempt=%u class=%s "
                "factory=%d raw=%d run=%d begin=%d sheet=%d URLs=%d "
                "URL=%d installed=%d\n", attempt, class_getName(openPanel),
                factory, rawFactory, run, begin, sheet, URLs, URL, installed);
        fflush(stderr);
    }
}

__attribute__((constructor))
static void MacWSLocalFilePanelInitialize(void) {
    // Foundation/NSObject is already an image dependency at this point. Build
    // runtime classes before AppKit's first panel request; if AppKit is loaded
    // later the bounded main-queue retry installs the construction hooks.
    BOOL classes = MacWSRegisterLocalFilePanelClasses();
    if (MacWSLocalFilePanelDiagnosticsEnabled()) {
        fprintf(stderr,
                "MACWS_FILE_PANEL constructor runtime-classes=%d\n", classes);
        fflush(stderr);
    }
    if (classes) MacWSInstallLocalFilePanelIfNeeded(0);
}
