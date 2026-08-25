# MacWSBootingGuide
Booting macOS's WindowServer on your jailbroken iDevice for real (WIP)

The current iPadOS multi-window, DisplayStream/IOSurface, touch, density, and
interop design is documented in
[`docs/displaystream-host-architecture.md`](docs/displaystream-host-architecture.md).
The direct presentation path does not require RFB/VNC; VNC remains a diagnostic fallback.

Some paths are currently hardcoded for rootless jailbreak, and some tools are hardcoded for Dopamine.

## One-command setup

The repository now includes `./macws-auto.sh`, which turns the old multi-step
host setup into a single automation entry point.

On a Mac:

```bash
chmod +x macws-auto.sh
./macws-auto.sh all
```

`all` will bootstrap Homebrew dependencies, clone/update RootHide Theos, download
the pinned iPhoneOS 16.5 SDK, link the macOS SDK, configure SSH access to the
jailbroken device, download a macOS 13.4 IPSW, provision `/var/mnt/rootfs`, build
all subprojects, create/install the RootHide `.deb`, post-process `libmachook`,
run `postinst.sh`, and load the macOS GUI launch daemons.

The default target is `172.20.10.3:2222` with `root/alpine`. Override it without
editing source:

```bash
MACWS_DEVICE_IP=192.168.1.50 \
MACWS_DEVICE_PORT=2222 \
MACWS_DEVICE_PASSWORD=alpine \
./macws-auto.sh all
```

For individual stages:

```bash
./macws-auto.sh bootstrap   # host toolchain + Theos + SDK
./macws-auto.sh rootfs      # macOS 13.4 filesystem/cryptex -> device rootfs
./macws-auto.sh install     # compile + install + postinst
./macws-auto.sh launch      # load macOS GUI daemons
./macws-auto.sh terminal    # open the macOS chroot shell
./macws-auto.sh status
./macws-auto.sh stop
```

The automation uses `ipsw` for macOS IPSW retrieval and DMG mounting. The project
still targets macOS 13.4/iOS 16.5-specific runtime assumptions, so the defaults
are intentionally pinned instead of silently using the newest macOS release.

## Manual setup / legacy entry point

`misc/build.sh` remains as a compatibility wrapper and now simply calls
`macws-auto.sh install`.

You need these simulator-runtime frameworks in the final package:
`MTLSimDriver.framework`, `MTLSimImplementation.framework`, and
`MetalSerializer.framework`.

## Starting up

The automated path runs the project's `layout/usr/macOS/bin/postinst.sh` after
installation. On the device, a manual shell is still available with:

```bash
bash /var/jb/usr/macOS/bin/run_bash.sh
```

To stop the GUI and restore iOS launch services:

```bash
./macws-auto.sh stop
```

## Running Claude Code in the chroot

The Claude Code native CLI can run inside the macOS chroot. The repository's
`autosignd` + `libmachook` path handles on-demand signing/trustcache registration.
The chroot still needs a working HTTP(S) proxy because its DNS setup is not the
same as iOS's host environment. See the existing Claude Code section below for
proxy and environment details.

## Additional patches

> [!NOTE]
> - Some offsets are hardcoded for iOS 16.5/macOS 13.4
> - [x] means automated or handled by hooks
> - [ ] means manual work is still required

### macOS side
- dyld still has an arm64/arm64e compatibility limitation documented below.
- launchservicesd still has an outstanding conversion item documented below.
- WindowServer and Metal compatibility work is handled by the project's runtime hooks and provisioning scripts.

## Credits
- [zhuowei/iOS-run-macOS-executables-tools](https://github.com/zhuowei/iOS-run-macOS-executables-tools)
- [SongXiaoXi/Reductant](https://github.com/SongXiaoXi/Reductant)
