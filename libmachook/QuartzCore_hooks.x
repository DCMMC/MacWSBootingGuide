@import CydiaSubstrate;
@import Darwin;
@import QuartzCore;
#import "interpose.h"

// Fix hangs
extern double NXClickTime();
extern void NXGetClickSpace();

double NXClickTime_new() {
    return 0.0;
}
void NXGetClickSpace_new() {}
DYLD_INTERPOSE(NXClickTime_new, NXClickTime)
DYLD_INTERPOSE(NXGetClickSpace_new, NXGetClickSpace)

int BlurState_tile_downsample() {
    return 0;
}

__attribute__((constructor)) static void InitQuartzCoreHooks() {
    // simulator's Metal doesn't support tile rendering, so skip it
    const char *quartzCorePath = "/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore";
    void *handle = dlopen(quartzCorePath, RTLD_GLOBAL);
    assert(handle);
    MSImageRef quartzCore = MSGetImageByName(quartzCorePath);
    MSHookFunction(MSFindSymbol(quartzCore, "__ZN2CA3OGL9BlurState15tile_downsampleEi"), (void *)BlurState_tile_downsample, NULL);
}
