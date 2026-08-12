#pragma once

#import <Foundation/Foundation.h>

BOOL MacWSHostDiagnosticsEnabled(void);
double MacWSMachMilliseconds(uint64_t start, uint64_t end);
void MacWSLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
