# Catalyst Keychain bridge — 2026-08-12

## Runtime boundary

Asphalt launches successfully through the foreground UIKit carrier as uid 501,
but its Ventura Security.framework client cannot initialize either storage
backend on iPadOS 16. Runtime diagnostics from the real application recorded:

```text
SecItem* default backend       -67674 (errSecMDSError)
SecItem* data-protection      -25291 (errSecNotAvailable)
identifierForVendor           present
device_launch_info deviceId   empty
```

`/usr/bin/security error -67674` identifies the first status as a Module
Directory Service error. Running Ventura `/usr/sbin/securityd` as uid 501
printed `You are not allowed to run securityd`; running it as root did not
provide the foreground user's storage domain. The stock macOS daemon is
therefore not a production prerequisite and no SecurityServer remap remains.

## Production design

`libmachook/Compatibility/MacWSCatalystKeychain.m` preserves native-first
semantics. It calls the real API, then proxies only `errSecNotAvailable` and
`errSecMDSError` from the exact Asphalt bundle. Requests are binary property
lists sent over the private `com.macwsguide.keychain` launchd service.

`macwskeychaind` runs as mobile in the iOS namespace and terminates every
operation in the real iPadOS Security framework. Its launch signature carries
the application's original Team ID and Keychain groups. It additionally
authenticates the XPC peer as uid 501 and Asphalt's exact executable path,
accepts only generic-password records and rejects reference/persistent-reference
results that cannot cross a process boundary. No credential is logged or
stored by MacWS itself.

Diagnostic entropy/identity markers are explicitly removed by production
preflight. The helper is independently restartable, and each proxied SecItem
operation opens a fresh connection so an earlier invalid launchd endpoint is
not cached for the application's lifetime.

## Remaining runtime gate

The bridge and all dependents compile locally. Device validation still requires
a reachable iPad SSH session: the last connection attempt timed out during SSH
banner exchange. The acceptance witness is an actual Asphalt launch where the
identity recorder changes only the final SecItem status to success and the game
advances beyond `CONNECTION ERROR`; registration/gameplay FPS must not be
claimed before that witness exists.
