# Neofetch latency on macPad (2026-09-15)

## Like-for-like baseline

Both hosts ran Neofetch 7.1.0 with the package's previous default disabled
fields and output redirected away. Three warm runs on the development Mac were:

```text
real 0.35
real 0.34
real 0.34
```

The same command in the iPad macOS chroot took 2.278-2.354 seconds after its
first run. The user-visible Terminal run, including rendering, had previously
reported 5.355 seconds.

## Runtime-confirmed cost breakdown

Even with every `print_info` field disabled, the 341,576-byte upstream Bash
script took 0.68-0.86 seconds on the iPad, versus 0.06-0.09 seconds locally.
The iPad's `bash neofetch --version`, which parses the script and exits before
normal collection, took 0.31-0.34 seconds; `bash -c :` took 0.06-0.07 seconds.

The all-disabled xtrace contains only these external probes before output:

```text
++uname -srm
++awk '-F<|>' '/key|string/ {print $3}' /System/Library/CoreServices/SystemVersion.plist
```

An individual iPad `uname` invocation took 0.11 seconds in three consecutive
runs. Field-isolation runs (all fields disabled except the named field) were:

| Field | iPad | Local Mac |
|---|---:|---:|
| none | 0.86 s | 0.09 s |
| model | 1.31 s | 0.28 s |
| uptime | 1.02 s | 0.07 s |
| wm | 0.97 s | 0.10 s |
| cpu | 0.95 s | 0.07 s |
| memory | 1.51 s | 0.08 s |

This runtime evidence identifies the upstream large-Bash-script parse plus its
many short-lived probe processes as the dominant cost in this chroot. It does
not attribute the delay to Terminal drawing alone.

## Production fast path

`macws-neofetch` collects the existing default core fields in one native
process using `sysctlbyname`, `uname`, `host_statistics64`, `time`, and one
read of `SystemVersion.plist`. It writes the complete colored logo and text in
one output buffer. Unsupported Neofetch options delegate to the original
`/opt/local/bin/neofetch`, so the complete upstream CLI remains available.

The first installed-candidate test in the real macOS Terminal rendered the
full colored logo and dynamic fields and printed:

```text
real    0m0.253s
user    0m0.129s
sys     0m0.049s
```

The same candidate with `--stdout` under the non-graphical chroot measured
0.26 seconds. These are measurements of this device session, not a latency
guarantee for every boot or load state.
