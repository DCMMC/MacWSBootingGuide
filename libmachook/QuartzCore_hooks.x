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

// CA::OGL::BlurState::tile_downsample(int) — used by NSVisualEffectView /
// CABackdropLayer blur pipeline to produce a downsampled version of the
// captured backdrop content.
//
// ROOT CAUSE of NSVisualEffectView rendering BLACK:
//   tile_downsample calls vtable[0x318] (the actual tile render), which
//   eventually invokes -[MTLSimDevice newRenderPipelineStateWithTileDescriptor:
//   options:reflection:error:]. That entire method in MTLSimDriver is a stub
//   that calls MTLReportFailure(@"not supported in the simulator") and returns
//   nil. Even _MTLDevice's base implementation returns a fresh NSError
//   "Tile render pipelines are not supported on this device". So tile rendering
//   is fundamentally unavailable in the MTLSim-bridged path no matter what
//   we hook.
//
// Stubbing tile_downsample to 0 here keeps WS alive (no MTL assertion crash)
// but produces no downsampled buffer → BlurState::apply_filter reads empty
// → backdrop output is solid clear color (black on iPad's framebuffer).
//
// To get real backdrop blur we would need ONE of:
//   (a) MTLSimDriver patched to forward newRenderPipelineStateWithTileDescriptor:
//       through XPC to MTLSimDriverHost, which calls iOS Metal's tile path
//       (iOS AGX on M1 DOES support tile rendering).
//   (b) Substitute BlurState::tile_downsample with a non-tile re-implementation
//       that uses standard compute/render pipelines and produces a compatible
//       downsampled pyramid for BlurState::apply_filter.
//   (c) Switch WS to FORCE_M1_DRIVER (native AGX) — blocked on iOS 16.3 by
//       Dopamine's missing PAC bypass (see memory: agx-direct-path-all-three-
//       paths-blocked).
//
// Until then, the stub return-0 stays as a defensive crash-prevention measure.
int BlurState_tile_downsample() {
    static int trace_count = 0;
    if (trace_count < 4) {
        fprintf(stderr, "#### BlurState::tile_downsample STUB -> 0 (MTLSim tile pipe unsupported; backdrop will render solid)\n");
        trace_count++;
    }
    return 0;
}

__attribute__((constructor)) static void InitQuartzCoreHooks() {
    const char *quartzCorePath = "/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore";
    void *handle = dlopen(quartzCorePath, RTLD_GLOBAL);
    assert(handle);
    MSImageRef quartzCore = MSGetImageByName(quartzCorePath);
    // MACWS_DISABLE_BLUR_TILE=1 keeps the defensive stub that returns 0
    // (used during earlier sessions when tile-pipeline creation hard-crashed
    // WS via MTLReportFailure). With the assert-NOP patches now covering ~50
    // CAWSBackend assertion sites + the SkyLight render_update fail-path
    // catch-all, the real tile path may complete (Metal's base impl returns
    // nil + NSError; that error path is more recoverable than a kernel
    // abort). Default: let original run.
    // Default: stub `BlurState::tile_downsample` to return 0. The original
    // function calls `MetalContext::get_tile_pipeline` which is hard-coded
    // to `abort_with_payload` if tile pipeline creation returns nil.
    // Even with our Metal_hooks tile→render-pipeline converter, QuartzCore's
    // internal compiler returns "Compiler internal error" on the substitute
    // descriptor (vertex/fragment IO mismatch), so we still get nil from
    // get_tile_pipeline → abort. Stub returns 0 → BlurState skips
    // tile_downsample_surface entirely → no abort → WS stays alive (vibrancy
    // panels render solid color, but the rest of compositing keeps working).
    //
    // MACWS_TRY_TILE_PIPELINE=1 disables the stub so the substitute path can
    // be exercised (development/debug only — currently crashes WS).
    if (!getenv("MACWS_TRY_TILE_PIPELINE")) {
        MSHookFunction(MSFindSymbol(quartzCore, "__ZN2CA3OGL9BlurState15tile_downsampleEi"),
            (void *)BlurState_tile_downsample, NULL);
        fprintf(stderr, "#### BlurState::tile_downsample STUB installed (set MACWS_TRY_TILE_PIPELINE=1 to disable)\n");
    } else {
        fprintf(stderr, "#### BlurState::tile_downsample stub DISABLED — original runs (will likely crash WS via get_tile_pipeline → abort_with_payload)\n");
    }
}
