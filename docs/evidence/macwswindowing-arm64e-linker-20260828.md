# MacWSWindowing arm64e linker invariant (2026-08-28)

## Runtime failure

ElleKit created `/var/mobile/.eksafemode` at `2026-08-28 00:14:30` after
loading the on-device-linked `MacWSWindowing.dylib` into SpringBoard PID 49490.
The resulting report was:

- `/var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-08-28-001431.ips`
- incident `76AAFE62-38A3-48DC-90EF-083CCDA3A7A2`
- `EXC_BREAKPOINT / SIGTRAP`
- faulting thread: `com.apple.main-thread`
- crash chain:
  `CFHash + 168 -> _CFXNotificationRegisterObserver + 216 ->
  __MacWSInstallRequestObservers_block_invoke (Tweak.x:967)`
- loaded MacWSWindowing UUID:
  `E29F734B-C60E-3891-BCE5-07434A8860C8`

The register dump annotated `__CFConstantStringClassReference` values with
invalid high bits while `CFNotificationCenterAddObserver` was consuming the
constant Darwin-notification name. This reproduced the earlier CFHash failure
even though the image contained `LC_DYLD_CHAINED_FIXUPS`.

## Linker comparison

`dyld_info -arch arm64e -fixups` provides the structural evidence.

The iPad/on-device lld image encoded every CF constant class reference as an
unauthenticated bind:

```text
__DATA_CONST __cfstring 0x0000C240 bind CoreFoundation/___CFConstantStringClassReference
```

The same source linked on macOS by Apple's ld64 encoded those fields as
authenticated data pointers:

```text
__DATA_CONST __cfstring 0x0000C310 auth-bind CoreFoundation/___CFConstantStringClassReference (div=0x6AE1 ad=1 key=DA)
```

Measured totals for the repaired image were `auth-bind/key=DA=79` and plain
`bind=0`. Therefore `-fixup_chains` is necessary for some on-device arm64e
images, but it is not sufficient for this SpringBoard tweak: the fixup payload
semantics also have to be correct.

## Enforced invariant

- `misc/deploy_macwswindowing.sh` builds on macOS and refuses deployment unless
  every arm64e `__cfstring` class reference is `auth-bind/key=DA` and none is a
  plain bind.
- It caches the validated binary and its SHA-256 under
  `/var/jb/var/mobile/macws-cross-build/`.
- `misc/build_on_ios.sh` verifies that cache before every full device build.
- The root `after-stage` rule replaces the unsafe device-linked intermediate
  with the validated Apple-ld64 artifact before packaging.
- `MacWSWindowing/Makefile` refuses an on-device build that does not declare
  the validated cross-build path.

## Recovery witness

After deploying the Apple-ld64 build and restarting SpringBoard, PID 49584
wrote:

```text
version=16 pid=49584 step=10 minimum=150 observers=main-queue-after-dyld fullscreen=exact-scene-activate-then-maximization-toggle-action-17 resize=app-layout-transaction exit=system-maximization-unzoom postcondition=host-scene-screen-geometry
```

`/var/mobile/.eksafemode` remained absent and no new SpringBoard crash report
was produced during the observation window.

The exact cached artifact later consumed by on-device packaging was then
installed and tested separately. Its installed and cached SHA-256 values both
equaled `fe89bf38b7f20d473c87dbbf52bf7a058fb3a6c5a6a53fc4157a79d0902f2905`;
SpringBoard PID 49998 published the same version-16 witness, the Safe Mode
marker remained absent, and no new SpringBoard crash report appeared.
