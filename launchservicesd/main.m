//
//  launchservicesd.m
//  
//
//  Created by Duy Tran on 3/8/25.
//

@import Darwin;
@import MachO;
#include <assert.h> 

void *dlopen_entry_point(const char *path, int flags) {
    int index = _dyld_image_count();
    void *handle = dlopen(path, flags);
    if(!handle) {
        printf("debugbydcmmc Failed to load launchservicesd.dylib: %s\n", dlerror());
        return NULL;
    } else {
        // printf("debugbydcmmc load launchservicesd.dylib successful\n");
    }
    uint32_t entryoff = 0;
    // printf("debugbydcmmc load launchservicesd.dylib before _dyld_get_image_header\n");
    const struct mach_header_64 *header = (struct mach_header_64 *)_dyld_get_image_header(index);
    // printf("debugbydcmmc load launchservicesd.dylib after _dyld_get_image_header\n");
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    for(int i = 0; i < header->ncmds; ++i) {
        if(command->cmd == LC_MAIN) {
            struct entry_point_command ucmd = *(struct entry_point_command *)imageHeaderPtr;
            entryoff = ucmd.entryoff;
            break;
        }
        imageHeaderPtr += command->cmdsize;
        command = (struct load_command *)imageHeaderPtr;
    }
    assert(entryoff > 0);
    // printf("debugbydcmmc launchservicesd.dylib entryoff %d\n", entryoff);
    return (void *)header + entryoff;
}

int main(int argc, const char **argv, const char **envp, const char **apple) {
    int( *original_main)(int argc, const char **argv, const char **envp, const char **apple) = dlopen_entry_point("@loader_path/launchservicesd.dylib", RTLD_GLOBAL);
    __attribute__((musttail))return original_main(argc, argv, envp, apple);
}
