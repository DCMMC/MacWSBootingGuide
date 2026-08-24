# metal2metal

`metal2metal` is MacWSBootingGuide's profile-driven AIR-to-AIR compatibility
layer. It retargets every AIR module in an exact source metallib, applies only
structurally registered lowerings, rebuilds and verifies the MTLB container,
and emits the runtime routing contract consumed by `libmachook`.

It is not a general Metal API proxy and it does not bypass the Metal compiler
or pipeline validation. The translated functions still pass through the real
iOS `MTLCompilerService` and AGX driver.

## Production contract

The installed entry point is:

```sh
python3 /var/jb/usr/macOS/bin/metal2metal.py translate \
  source.metallib output.metallib \
  --llvm-dis /var/jb/usr/lib/llvm-16/bin/llvm-dis \
  --llvm-as /var/jb/usr/lib/llvm-16/bin/llvm-as \
  --auto-lower-known-air \
  --runtime-manifest output.route.plist \
  --runtime-source-path /System/path/source.metallib \
  --runtime-output-path /usr/local/share/macws/output.metallib
```

A production runtime manifest is accepted only when all source functions were
translated under one named profile. `--function` remains available for
offline diagnostics and application-specific artifacts, but cannot be
combined with `--runtime-manifest`. This is deliberate: a hand-maintained
allow-list cannot silently become the production coverage boundary again.

The manifest records:

- the profile and translator schema versions;
- exact source and output size, SHA-256 and FNV-1a identities;
- the complete source/translated function set;
- MTLB function type and structurally detected function constants;
- per-module input/output hashes and applied semantic lowerings.

`libmachook` discovers `*.route.plist` files under
`/usr/local/share/macws/metal2metal/routes`, validates both artifacts and
requires equality of the complete source and translated function sets before
accepting a route. It attributes a library by its exact URL, or by equality of
the entire function-name set when a private framework bypasses the public URL
load boundary. A shader name alone is never accepted as provenance, and an
ambiguous URL or function set disables the route.

## Fail-closed boundaries

- Unknown source container targets, malformed sections or hash mismatches are
  rejected.
- AIR/container target disagreement is rejected.
- A registered intrinsic with an unknown call shape is rejected instead of
  being approximately rewritten.
- A single module that cannot be disassembled, lowered, reassembled or
  re-verified aborts complete-library production translation.
- Runtime target overrides are rejected; they require a new reviewed profile.
- Missing, stale, partial or ambiguous runtime manifests disable routing.

The compatibility implementation remains in
`misc/repack_metallib_macabi.py` so existing offline commands keep working.
New production callers must use the `metal2metal.py` command surface.

## Verification

```sh
python3 misc/metal2metal.py verify-runtime-manifest output.route.plist \
  --source source.metallib --output output.metallib
python3 -m unittest misc/test_repack_metallib_macabi.py
```

Translation success is a static compiler witness, not a rendering witness.
For a new profile or source-library version, acceptance still requires device
library loading, function specialization/pipeline creation, and visible output
or the relevant application-specific runtime witness.
