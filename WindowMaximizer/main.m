#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            NSLog(@"Usage: %s <PID>", argv[0]);
            return 1;
        }
        
        pid_t pid = (pid_t)atoi(argv[1]);
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        
        if (app) {
            // Bring app to front
            [app activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
        } else {
            NSLog(@"No NSRunningApplication for pid %d", pid);
        }
    }
    return 0;
}
