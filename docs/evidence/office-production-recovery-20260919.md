# Office production rendering recovery, 2026-09-19

## Acceptance boundary

The reported missing Office pictures and black PowerPoint thumbnails have
two independently measured upstream failures, not a reason to disable native
AGX, fake successful allocations, or bypass the compiler's validation:

1. The ordinary unpinned NoCopy producer sends a 104-byte macOS record to a
   96-byte native ABI. The former detached-copy/early-deallocator workaround
   breaks aliasing and lifetime. The version-checked wire translation now
   preserves the real initializer, original CPU memory and eventual callback.
2. Office's original 28-function Metal2DShaders library is admitted, but its
   actual bitmap specialization returns `Target OS is incompatible.` The
   complete AIR library is translated using the packaged Apple LLVM tools.
   All instructions, interfaces and function constants are preserved; exact
   source identity selects the validated companion, with no check bypass.

See `office-nocopy-contract-20260919.md`,
`office-metal-library-target-20260919.md` and
`office-image-stride-20260919.md` for actual binary offsets, negative controls,
mapped identities, copied errors and pixel comparisons.

## Actual application pixels

The cross-linked candidate `03558D10-1BA7-3C07-A680-761E6281E60E` was
verified in each owned application through read-only mapped-image inspection,
not inferred from installed filenames. No observer or diagnostic marker was
used for these three runs. The main agent inspected all screenshots:

| Application | Owned PID/window | Visible result | Screenshot |
| --- | --- | --- | --- |
| Word | 46877/283 | Previously absent toolbar and menu pictures restored | `/tmp/macws-word-contract-images-20260919.png` |
| Excel | 47766/299 | Welcome logo and owl pictures present | `/tmp/macws-excel-contract-initial-20260919.png` |
| PowerPoint | 48246/306 | All four slide-3 pictures and visible colored thumbnails restored | `/tmp/macws-ppt-contract-slide3-20260919.png` |

All three owned processes exited normally (receipt return code 0). Only the
test-owned Excel document's explicit Don't Save dialog was dismissed. User
PowerPoint19000 and Terminal17280 remained running and were not quit.

These screenshots do not certify every Office document, animation, chart or
rendering path. Subsequent provenance-policy hardening and the final on-device
LLVM package require their own post-build/post-install acceptance; this
candidate's UUID must not be attributed to the later build.

## Production and upgrade contracts

- Installation and ordinary startup provision the whole Office library by
  default. No `/tmp` flag enables rendering. The optional boot-ready record
  only avoids repeated verification; a new boot or missing record rechecks
  the immutable source/output identities.
- Office snapshots and companions are derived shader data, not feature flags.
  They are atomically published only after complete manifest verification.
  The original application archives are never modified. Updates and corrupt
  outputs invalidate the cache; one broken application does not prevent
  provisioning the others or starting the desktop.
- Public data attribution requires exact size and SHA-256. Office manifests
  reject private function-name-only inference. Negative attribution remains
  authoritative. Hashing/manifest reads do not run per frame.
- Boot fingerprints include nanosecond timestamps, resources, provisioner
  and generated artifacts. Executable tests include same-second same-length
  corruption, missing files, failed conversion and concurrent provisioning.
- The archive gate now checks every source payload in the actual Debian
  archive, including the Office helper and Metal conversion scripts. All 21
  artifact tests executed successfully on the iPad with real `dpkg-deb`;
  the 12 archive cases are skipped on the development Mac without that tool.
- Weather signing now uses a fresh inode, validates and trustcaches it before
  publication. Existing mapped executable pages are not re-signed in place.
  The real shell transaction passes normal publication and nine failure
  cases without modifying the original executable.

## Other measured repairs included in this source generation

The shared proxy obtains the real root path before chroot; a clean environment
uses kernel root-vnode identity instead of a fragile inherited enable value.
The previously recurring macOS locationd loop has not recurred in its tested
generation: the post-Office follow-up retained PID23153, `runs = 1`,
`last exit code = (never exited)`, after a completed CoreLocation API query.
Top-level crash metadata still ended at the earlier 16:47 locationd report;
this is bounded evidence, not a claim that all crash/heat issues are solved.

Other narrow changes preserve IOSurface's actual protection/per-plane ABI,
admit structurally valid zero-depth Weather commands, implement the missing
sendfile fallback, and remove repeated disabled-diagnostic filesystem queries
and successful-call logging. Their separate evidence files distinguish API
tests from whole-application acceptance. Finder PDF/TXT icons and intermittent
Preview annotation rendering are **not** certified by this Office acceptance.

## Final on-device build and executable controls

Source commit `9b88667864e02c2a5f41509d75cd64ffa52e800a` was pushed and
fast-forwarded into the clean device checkout. The complete
`THEOS=/var/jb/var/mobile/theos MAKEFLAGS=-j2 bash misc/build_on_ios.sh --package-only`
build succeeded. The Apple-ld64 Windowing artifact was rebuilt/staged first,
with 179 authenticated CF-string fixups and zero plain CF-string binds.
The actual package and Host ABI admission gates passed; this phase did not
install or restart applications.

Package `com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb` SHA-256:
`7a4fb82c57a2b3b597f638e39a4df41ee3f16e2073a1ee6070465b8287a8a01d`.
The library was extracted from that archive, split, platform-patched, signed
and admitted under fresh isolated paths before any production installation:

| Slice | UUID | Signed isolated SHA-256 |
| --- | --- | --- |
| arm64 | `5EC31E06-F7D0-38CE-9989-34862E420C21` | `be9b20c1be4164bbf5996ee363e04a7bb05b0ef9376bd9166c2eb9bbaf979c8b` |
| arm64e | `D25AFFEA-E257-3921-A845-785A6012ACBA` | `ddbc67a63f859e42384bfe4170279bcfa1d3e3f62998efce8cbac6295782dc71` |

Both actual slices passed Shared/Managed NoCopy ownership and GPU writes,
the real Office bitmap specialization/reflection/render with **0/77250**
pixel mismatches, a GPU render followed by a successful fork, namespace
resource-property protocols before/after fork, and public sendfile exact-byte
checks. IOSurface layout checks likewise reported zero disagreements for
both slices. Logs:

- `/tmp/macws-office-package-candidate-20260919.log`
- `/tmp/macws-office-package-contracts-20260919.log`
- `/tmp/macws-office-package-helper-admission-20260919.log`
- `/tmp/macws-office-release-layout-checks-20260919.log`

One initial arm64e namespace test was killed before output. The initial
inspection mistakenly checked the arm64 fixture's CDHash; reviewing the full
log correctly located the failure in the arm64e phase. The arm64e fixture
also failed against the older canonical library. Its actual CDHash
`9468a189c9097c038be72d8f55fe8b72e96d3f1c` was absent from the device trustcache.
After admitting that exact unchanged test binary, its namespace/fork checks
passed with the unchanged new library. No production bypass or code change
was made to hide the failed run. Two attempted native logging tools also
failed during this diagnosis; their reports must not be counted as new Office
or locationd failures.

The full local suite ran 414 cases: 402 executed successfully and 12 archive
cases were skipped for missing local `dpkg-deb`; all those archive cases were
executed successfully on the device as part of the 21-case artifact suite.
The source-policy inventory passed (275 environment names, 76 source flag
paths, 423 recorded entries). A separate read-only device check found no
registered diagnostic flag present in either the iOS or chroot namespace.

## Production installation

The exact verified Debian archive was installed successfully with
`MACWS_POSTINST_NO_RESPRING=1`. `dpkg` returned 0 and reported
`install ok installed`. Source/staging/archive gates were run again immediately
before installation. The maintenance script verified all 49 Settings panes,
the unchanged original Office archives and the complete 28-function route.
It refreshed autosignd and verified its endpoint, but deferred loaded
hostd/input/Dock/keychain jobs. No SpringBoard or GUI-stack restart occurred.

Package-storage and rootfs copies match byte-for-byte for each final slice:

| Installed basename | Final signed SHA-256 |
| --- | --- |
| `libmachook_arm64.dylib` | `273edeca9604272d4305b6c7f9b630d011367ce8c530701ca95ca8084454a141` |
| `libmachook.dylib` (arm64e) | `885d51f36af050e8833f0b9bfe7e1f2bb353ef42f826aa8344b5547576301e15` |

UUIDs remain the on-device build identities above. Post-install probes loaded
the actual canonical `/usr/local/lib/` files, not the isolated `/tmp` copies.
Both again rendered the real Office bitmap with zero pixel/byte mismatches,
kept stock superclass authentication and completed GPU work followed by
fork/exit0. Receipt: `/tmp/macws-office-installed-bitmap-fork-20260919.log`.

The complete before/after read-only mapped-image outputs for user PPT19000,
Terminal17280 and WindowServer16900 were identical, including load address,
UUID and text SHA-256. Their original start times, and SpringBoard315/Dock17120/
hostd8928/locationd23153, were preserved. This protects existing documents;
it **does not** mean those old processes magically loaded the new library.
In particular, the user's old PowerPoint must be saved and normally reopened
before its own document uses the repaired rendering path.

Installation log: `/tmp/macws-office-package-install-20260919.log`.
The four previous runtime files were retained under the scoped recovery
directory `/tmp/macws-office-preinstall.Xc1EFx`; no user file was removed.

Post-install visual acceptance also used the canonical arm64 path and verified
its actual mapped UUID/text identity. The main agent inspected:

- Word67368/window322:
  `/tmp/macws-office-installed-release-20260919-word-images.png` shows both
  formerly absent toolbar/menu pictures with their original colors.
- Excel67644/window329:
  `/tmp/macws-office-installed-release-20260919-excel-images.png` shows the
  white Excel logo, orange owl, green background, text and sheet controls.

The package's earlier PowerPoint63261/window316 slide-3 screenshot likewise
shows all four pictures and nonblack thumbnails. These are three real owned
Office fixtures, not a claim that the still-running user's old PPT was
hot-repaired. The no-flag canonical shader/fork controls and application
screenshots close the reported Office image/thumbnail acceptance for this
installed source generation. They do not close the unrelated pending
Finder-icon/Preview-annotation matrix or certify an actual iPad reboot.
