// mingpu.m — MINIMAL standalone AGX GPU repro of the core chroot wall (2026-06-24).
// Build (macOS arm64): clang -fobjc-arc -framework Foundation -framework Metal -framework IOSurface -o mingpu mingpu.m
// Run LOCAL macOS: all pass (render-clear status=4, blit status=4, readback=red 0000ffff).
// Run CHROOT (libmachook + MACWS_AGX_NATIVE=1 MACWS_AGX_REGISTER_CLASSES=1 MACWS_PIN_FALLBACK=1):
//   device/IOSurface/texture/queue create OK; ALL AGXIOC IOConnectCallMethod calls return 0
//   (sel=0x9/0xa ResCreate inSC=104 outSC=80 -> 0, sel=0x8 queue create -> 0); BUT GPU EXECUTION
//   FAILS: render-clear -> status=5 0x102 (Internal Error), blit -> status=5 0xb (page fault),
//   readback empty. ⟹ the chroot can CREATE GPU resources but the GPU-side MAPPING is invalid;
//   the GPU MMU faults accessing them. This is the core IOSurface-GPU-registration wall, isolated.
//   Same 0x102 the WS composite-blit injection hit. Local vs chroot diff = GPU resource mapping.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#define LOG(...) do{ fprintf(stderr,"[MINGPU] " __VA_ARGS__); fprintf(stderr,"\n"); }while(0)
int main(){@autoreleasepool{
  id<MTLDevice> dev=MTLCreateSystemDefaultDevice();
  LOG("device=%s unified=%d", dev?[dev.name UTF8String]:"NIL", dev?(int)[dev hasUnifiedMemory]:-1);
  if(!dev) return 1;
  int W=256,H=256;
  NSDictionary*sp=@{(id)kIOSurfaceWidth:@(W),(id)kIOSurfaceHeight:@(H),(id)kIOSurfacePixelFormat:@(0x42475241),(id)kIOSurfaceBytesPerElement:@4,(id)kIOSurfaceBytesPerRow:@(W*4),(id)kIOSurfaceAllocSize:@(W*H*4)};
  IOSurfaceRef ss=IOSurfaceCreate((__bridge CFDictionaryRef)sp);
  IOSurfaceRef ds=IOSurfaceCreate((__bridge CFDictionaryRef)sp);
  LOG("src ios=%p dst ios=%p", ss, ds);
  MTLTextureDescriptor*sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
  sd.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead; sd.storageMode=MTLStorageModeShared;
  id<MTLTexture> stex=[dev newTextureWithDescriptor:sd iosurface:ss plane:0];
  id<MTLTexture> dtex=[dev newTextureWithDescriptor:sd iosurface:ds plane:0];
  LOG("stex=%p dtex=%p", stex, dtex);
  id<MTLCommandQueue> q=[dev newCommandQueue]; LOG("queue=%p", q);
  id<MTLCommandBuffer> cb=[q commandBuffer];
  MTLRenderPassDescriptor*rp=[MTLRenderPassDescriptor new];
  rp.colorAttachments[0].texture=stex; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
  rp.colorAttachments[0].clearColor=MTLClearColorMake(1,0,0,1); rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  id<MTLRenderCommandEncoder> r=[cb renderCommandEncoderWithDescriptor:rp]; [r endEncoding];
  [cb commit]; [cb waitUntilCompleted];
  LOG("PASS1 render-clear-red: status=%ld err=%s", (long)[cb status], [cb error]?[[[cb error] localizedDescription] UTF8String]:"none");
  id<MTLCommandBuffer> cb2=[q commandBuffer];
  id<MTLBlitCommandEncoder> bl=[cb2 blitCommandEncoder];
  [bl copyFromTexture:stex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toTexture:dtex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
  [bl endEncoding]; [cb2 commit]; [cb2 waitUntilCompleted];
  LOG("PASS2 blit src->dst: status=%ld err=%s", (long)[cb2 status], [cb2 error]?[[[cb2 error] localizedDescription] UTF8String]:"none");
  IOSurfaceLock(ds,0x1,NULL); uint8_t*b=(uint8_t*)IOSurfaceGetBaseAddress(ds);
  LOG("dst readback px(128,128)=%02x%02x%02x%02x (expect 0000ffff = red BGRA)", b[128*W*4+512],b[128*W*4+513],b[128*W*4+514],b[128*W*4+515]);
  IOSurfaceUnlock(ds,0x1,NULL);
  LOG("DONE ok");
  return 0;
}}
