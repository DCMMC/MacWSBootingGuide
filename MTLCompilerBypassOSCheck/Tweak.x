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
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

// Xcode 18.x SDKs provide the canonical xpc_data_create declaration via
// <xpc/xpc.h> transitively. Do not redeclare it as void *: under ARC that
// conflicts with xpc_object_t and also requires an explicit bridge when the
// retained XPC object is returned through this C-compatible void * hook.

