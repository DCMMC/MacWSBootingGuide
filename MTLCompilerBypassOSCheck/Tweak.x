@import CydiaSubstrate;
@import Foundation;
@import Darwin;

void ModifyExecutableRegion(void *addr, size_t size, void(^callback)(void)) {
    vm_protect(mach_task_self(), (vm_address_t)addr, size, false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    callback();
    vm_protect(mach_task_self(), (vm_address_t)addr, size, false, PROT_READ | PROT_EXEC);
}

%ctor {
    NSLog(@"#### debugbydcmmc MTLCompilerBypassOSCheck start");
    dlopen("/System/Library/PrivateFrameworks/MTLCompiler.framework/MTLCompiler", RTLD_GLOBAL);
    MSImageRef image = MSGetImageByName("/System/Library/PrivateFrameworks/MTLCompiler.framework/MTLCompiler");
    assert(image);
    uint32_t *symbol = MSFindSymbol(image, "__ZN17MTLCompilerObject27readModuleFromBinaryRequestERK20ReadModuleParametersRN4llvm11LLVMContextEP15MTLFunctionTypePPvPmb");
    assert(symbol);
    NSLog(@"#### debugbydcmmc MTLCompilerBypassOSCheck find symbol");
    
    // 0x1eaaa17c4 <+608>:  ldr    w8, [sp, #0x84]
    // 0x1eaaa17c8 <+612>:  cmp    w8, #0x7
    // 0x1eaaa17cc <+616>:  b.ne   0x1eaaa1840 (throws "Target OS is incompatible.")
    while(symbol[0] != 0xb94087e8) {
        symbol++;
    }
    assert(symbol[1] == 0x71001d1f);
    //assert(symbol[2] == 0x540003a1);
    ModifyExecutableRegion(symbol + 2, sizeof(uint32_t), ^{
        symbol[2] = 0xd503201f; // nop
    });
    NSLog(@"#### debugbydcmmc MTLCompilerBypassOSCheck modify successfully!");
}
