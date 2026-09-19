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
