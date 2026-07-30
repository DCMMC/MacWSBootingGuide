# First post-P-core native-AGX error: type-5 padding gate

The 60,000-fish VS Code Aquarium run reproduced a real native-AGX completion
error after the launchd performance-class change. The getter and fixed-size
submit ring correlated the first error to GPU PID 48199, submit serial 12887,
queue sequence 14985, descriptor 0. The complete command stream is 552 bytes
and the complete segment list is 264 bytes, so this is not the earlier
64-KiB inspector-cap failure.

The ring manifest records `fixed=0`. The command stream contains one macOS
vendor subtype-3 record over `[0,0x210)`, followed by a type-5 0x18-byte
record over `[0x210,0x228)`. Its six dwords are:

```
{5, 0x18, 1, 0x15, 1, 0}
```

The final generation-4 wrapper list covers exactly `[0x210,0x228)`. The old
translator accepted the same shape only when the last record was
`{5,0x18,N,0,1,0}` with `N` in 1...3. It consequently rejected this complete
record solely because the dword at record+0x0c was 0x15.

`iogpu-signal-event-disassembly.txt` is the actual macOS 13.4 IOGPU
disassembly. It proves that the type-5 producer writes the event identifier at
record+0x08 and the caller's arbitrary 64-bit signal value at record+0x10,
but never writes record+0x0c. That dword is unspecified padding. The source
change therefore preserves the entire type-5 command byte-for-byte and removes
only false semantic checks on its payload; the exact wrapper-list bounds and
generation anchors remain mandatory before the preceding RE-confirmed
subtype-3 record can be translated.

The post-change runtime result must still be captured on the iPad. Until that
test completes, this is an RE-backed correction with a pending stability
witness, not a completed stability milestone.
