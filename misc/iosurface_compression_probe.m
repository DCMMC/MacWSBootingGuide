// Native-iOS, read-only IOSurface compression metadata probe.
//
// This intentionally does not create a Metal device.  It reconstructs the
// two-plane 2388x1668 pf550 IOSurface captured from WindowServer and compares
// the public property dictionary with the private IOSurface query APIs that
// macOS AGXMetal13_3 calls before updateBindDataWithAddresses:... .

@import Foundation;
@import IOSurface;

#import <stdint.h>
#import <stdio.h>

extern uint32_t IOSurfaceGetCompressionTypeOfPlane(IOSurfaceRef surface,
                                                    size_t plane);
extern size_t IOSurfaceGetHeightInCompressedTilesOfPlane(
    IOSurfaceRef surface, size_t plane);
extern size_t IOSurfaceGetBytesPerRowOfPlane(IOSurfaceRef surface,
                                             size_t plane);
extern uint32_t IOSurfaceGetAddressFormatOfPlane(IOSurfaceRef surface,
                                                 size_t plane);

static NSDictionary *plane(BOOL second) {
    return @{
        @"IOSurfaceAddressFormat": @5,
        @"IOSurfacePlaneBytesPerCompressedTileHeader": @8,
        @"IOSurfacePlaneBytesPerElement": @(second ? 256 : 1024),
        @"IOSurfacePlaneBytesPerRow": @(second ? 38400 : 153600),
        @"IOSurfacePlaneBytesPerRowOfTileData": @(second ? 38400 : 153600),
        @"IOSurfacePlaneBytesPerTileData": @(second ? 256 : 1024),
        @"IOSurfacePlaneCompressedTileDataRegionOffset":
            @(second ? 16390144 : 0),
        @"IOSurfacePlaneCompressedTileHeaderRegionOffset":
            @(second ? 20422144 : 16128000),
        @"IOSurfacePlaneCompressedTileHeight": @16,
        @"IOSurfacePlaneCompressedTileWidth": @16,
        @"IOSurfacePlaneCompressionFootprint": @0,
        @"IOSurfacePlaneCompressionType": @3,
        @"IOSurfacePlaneElementHeight": @16,
        @"IOSurfacePlaneElementWidth": @16,
        @"IOSurfacePlaneHeight": @1668,
        @"IOSurfacePlaneHeightInCompressedTiles": @105,
        @"IOSurfacePlaneOffset": @(second ? 16390144 : 0),
        @"IOSurfacePlaneSize": @(second ? 4294144 : 16390144),
        @"IOSurfacePlaneWidth": @2388,
        @"IOSurfacePlaneWidthInCompressedTiles": @150,
    };
}

int main(void) {
    @autoreleasepool {
        NSDictionary *properties = @{
            @"IOSurfaceAllocSize": @20684288,
            @"IOSurfaceCacheMode": @1792,
            @"IOSurfaceHeight": @1668,
            @"IOSurfaceMapCacheAttribute": @0,
            @"IOSurfaceMemoryRegion": @"PurpleGfxMem",
            @"IOSurfaceName": @"MacWS native compression API probe",
            @"IOSurfacePixelFormat": @643969848,
            @"IOSurfacePixelSizeCastingAllowed": @0,
            @"IOSurfacePlaneInfo": @[plane(NO), plane(YES)],
            @"IOSurfaceWidth": @2388,
        };
        IOSurfaceRef surface = IOSurfaceCreate(
            (__bridge CFDictionaryRef)properties);
        if (!surface) {
            fprintf(stderr, "IOSURFACE-COMPRESSION-PROBE create failed\n");
            return 2;
        }
        CFDictionaryRef actual = IOSurfaceCopyAllValues(surface);
        NSDictionary *root = (__bridge NSDictionary *)actual;
        id creationValue = [root objectForKey:@"CreationProperties"];
        NSDictionary *creation =
            [creationValue isKindOfClass:[NSDictionary class]]
                ? (NSDictionary *)creationValue : root;
        NSArray *planes = [creation objectForKey:@"IOSurfacePlaneInfo"];
        for (size_t index = 0; index < 2; index++) {
            NSDictionary *actualPlane = index < [planes count]
                ? [planes objectAtIndex:index] : nil;
            fprintf(stderr,
                "IOSURFACE-COMPRESSION-PROBE plane=%zu propertyType=%s "
                "propertyHeightInTiles=%s propertyBytesPerRow=%s "
                "propertyAddressFormat=%s apiType=%u apiHeightInTiles=%zu "
                "apiBytesPerRow=%zu apiAddressFormat=%u\n",
                index,
                [[[actualPlane objectForKey:@"IOSurfacePlaneCompressionType"]
                    description] UTF8String] ?: "(nil)",
                [[[actualPlane objectForKey:
                    @"IOSurfacePlaneHeightInCompressedTiles"] description]
                    UTF8String] ?: "(nil)",
                [[[actualPlane objectForKey:@"IOSurfacePlaneBytesPerRow"]
                    description] UTF8String] ?: "(nil)",
                [[[actualPlane objectForKey:@"IOSurfaceAddressFormat"]
                    description] UTF8String] ?: "(nil)",
                IOSurfaceGetCompressionTypeOfPlane(surface, index),
                IOSurfaceGetHeightInCompressedTilesOfPlane(surface, index),
                IOSurfaceGetBytesPerRowOfPlane(surface, index),
                IOSurfaceGetAddressFormatOfPlane(surface, index));
        }
        if (actual) CFRelease(actual);
        CFRelease(surface);
    }
    return 0;
}
