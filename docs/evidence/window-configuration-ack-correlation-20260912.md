# ConfigureWindow responses must identify their request

Status: Host implementation and unit regression tests complete; producer,
transport, and main-controller integration are concurrent work. Device visual
acceptance is still required.

## Runtime witness

Copied verbatim from the running iPad's
`/var/mobile/Library/Logs/MacWSHost.log`:

```text
1789154729.441 window-configuration constrained window=193 pid=36019 requested=736.0x634.0 applied=648.0x613.0 source=604.0x613.0 resizable=YES published-minimum=NO
1789154729.442 window-size constrained-follow window=193 pid=36019 requested-logical=736.0x634.0 applied-logical=648.0x613.0
1789154729.442 window-configuration scene-follow armed window=193 pid=36019 target-logical=648.0x613.0
1789154729.460 window-configuration queued-request-superseded window=193 pid=36019 target-logical=648.0x613.0
1789154733.292 window-configuration constrained window=193 pid=36019 requested=968.0x670.0 applied=967.0x429.0 source=912.0x636.0 resizable=YES published-minimum=NO
1789154733.321 window-configuration queued-request-superseded window=193 pid=36019 target-logical=967.0x429.0
```

These lines establish the observed backward Scene resize and cancellation of
a queued newer configure. They do **not** establish which historical request
produced 648x613: the old catalog carried no configuration request identity.

Source inspection of the old Host shows that
`observeTargetWindowLogicalSize:` compared every changed catalog frame with
`_pendingRequestedWindowSize`. The latter could already hold an unsent request
in the 33-ms coalescing queue. The old 220-ms timer also guessed a fixed-size
response from whichever catalog happened to be present. Neither path had the
information required to label the observation as a response to that request.

## Implemented Host invariant

- The issued request retains its original input timestamp and sample sequence.
- The producer must echo that key, requested dimensions, and the synchronous
  `setFrame` result; only a matching reply can report an AppKit constraint.
- An already queued newer Scene size supersedes a matching older reply.
- Retries preserve the transaction key, rather than creating a new identity.
- A catalog or IOSurface from a legacy producer can prove exact convergence,
  but an unequal size cannot become a constrained response.
- The bounded 220-ms timer requests a fresh snapshot; it does not infer an ACK.

The existing DPI sampling correction is unchanged.

## Local checks

```sh
clang -std=c11 -Wall -Wextra -Werror -Iinclude misc/macws_window_configuration_test.c -o /tmp/macws_window_configuration_test
/tmp/macws_window_configuration_test
clang -std=c11 -Wall -Wextra -Werror -Iinclude misc/macws_drawable_resolution_test.c -o /tmp/macws_drawable_resolution_test
/tmp/macws_drawable_resolution_test
```

Both pass. The ACK tests cover an unrelated earlier response, an unsent newer
size, a queued density change, a real fixed/increment constraint, matching
retries, reused sequence numbers after restart, and a legacy catalog without
an ACK. `MacWSMetalView.m` compiles successfully for arm64. A complete Host
build awaits the concurrent main-controller interface updates.
