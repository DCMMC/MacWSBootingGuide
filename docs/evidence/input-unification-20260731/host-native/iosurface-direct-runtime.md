# MacWS Host IOSurface 直传运行证据（2026-07-31）

目标设备：`iPad13,6`，iPadOS 16.3.1；温控采样为 `nominal`。测试没有重启 iPad、WindowServer 或 macOS GUI，只重新构建和启动了 MacWS Host。

## 传输边界

MacWS Host 的生产路径是：

```text
SLSHWCaptureStreamCreateWithWindow
  → IOSurface Mach right over XPC
  → IOSurfaceLookupFromMachPort
  → MTLTexture
  → MTKView
```

它不包含 RFB encoder、RFB client、zlib/tight/hextile 或 TCP 5900。VNC-enabled coexist 会话里的独立 `OSXvnc-server` 只服务传统 VNC 客户端，不是 Host 的帧源。

安装后的启动日志明确记录生产默认关闭旧 mmap：

```text
1785484189.694 launched native-device=Apple M1 GPU supportsMultiple=YES display-transport=IOSurface legacy-mmap=disabled frame-path=/var/mnt/rootfs/private/tmp/macws_vnc_fb
```

单窗口 Scene 的首帧直接来自 IOSurface；没有先显示全屏 mmap crop：

```text
1785484259.205 scene-connected id=A14E1EE1-A239-477B-89BF-3A232EB04A2D role=UIWindowSceneSessionRoleApplication mode=2 window=37
1785484259.207 display-stream status connected=YES message=DisplayStream IOSurface 直传已连接
1785484259.305 runtime-confirmed native Metal present scene=b505a8c57736e298 frame=1770x1156 source=IOSurface status=4 error=nil
MACWS-DISPLAY stream-start id=10 mode=2 window=37
```

## 原生输入结果

10 秒、60 Hz 连续拖动：

- 发送 move：600
- AppKit drag：599（59.88 Hz）
- latency p50：0.565 ms
- latency p95：0.806 ms
- max：11.39 ms
- down/up 顺序：完整

完整原始结果见 `motion-60hz-direct-10s.log`；点击、右键、滚动和键盘组合见 `semantic-matrix.json`。

## 当前剩余显示瓶颈

先在 VNC-enabled coexist 会话中记录：

```text
MACWS-DISPLAY throughput stream=8 window=37 frames=120 elapsed=35.899 ... outstanding=2 dropped=41
MACWS-DISPLAY throughput stream=8 window=37 frames=240 elapsed=38.884 ... outstanding=3 dropped=64
MACWS-DISPLAY throughput stream=8 window=37 frames=360 elapsed=42.041 ... outstanding=2 dropped=105
```

相邻接受序号计算得到 40.2 fps 和 38.0 fps。随后只重启 macOS GUI 会话为 `coexist --no-vnc --no-terminal`；进程表中没有 `OSXvnc-server`，control 状态明确为 `frame=NO`，但窗口 4 仍以 `source=IOSurface` 完成 Metal present。纯直传 10 秒结果：

```text
MACWS-DISPLAY throughput stream=8 window=4 frames=120 elapsed=18.783 ... outstanding=2 dropped=40
MACWS-DISPLAY throughput stream=8 window=4 frames=240 elapsed=21.993 ... outstanding=2 dropped=75
MACWS-DISPLAY throughput stream=8 window=4 frames=360 elapsed=25.099 ... outstanding=3 dropped=103
```

相邻区间为 37.4 fps、38.6 fps，与 VNC-enabled 结果同一量级。运行日志同时显示 Metal submit-to-complete 约 1.6–2.5 ms；因此“RFB 压缩导致 Host 卡顿”已被运行 A/B 排除。租约释放、主线程呈现节拍与 producer callback 的具体责任比例仍需继续量化，当前不把 THEORY 写成根因。
