# Open Panel、完整桌面、Electron 弹层与 Terminal 动态帧修复 — 2026-08-01

目标设备：`iPad13,6`、iPadOS 16.3.1、chroot macOS 13.4，地址
`192.168.1.6`。本轮没有重启 iPad，也没有降低或绕过任何温控、内存
安全阈值。

## 1. VSCode Open File

VSCode 的实际日志连续记录：

```text
[main 2026-07-31T16:50:00.649Z] [DialogMainService]: file open dialog is already or will be showing for the window with the same configuration
[main 2026-07-31T16:50:14.174Z] [DialogMainService]: file open dialog is already or will be showing for the window with the same configuration
```

runtime-confirmed via `/var/jb/var/mobile/vscode.log:451133-451134`：第一次
open dialog 没有完成，Electron 因而把第二次请求判定为同一窗口已有对话框在途。

目标 macOS 根文件系统中真实服务存在：

```text
/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/
  com.apple.appkit.xpc.openAndSavePanelService.xpc
CFBundleIdentifier = com.apple.appkit.xpc.openAndSavePanelService
NSPrincipalClass = NSViewServiceApplication
```

此前 `libmachook` 的 `_xpc_bootstrap_services` 只注册 Metal、ViewBridge 和
HIServices 的 owning framework，没有注册 AppKit。现在用同一真实 bootstrap
机制加入 `/System/Library/Frameworks/AppKit.framework/AppKit`，让 AppKit 自己
的 open/save panel XPC service 进入同一服务注册流程；没有替换 `NSOpenPanel`、
伪造结果或把失败检查改成成功。**THEORY**：缺少 owning framework bootstrap 是
这次 panel 一直在途的上游原因；只有新包中 Open/Cancel 都能结束并且对应 XPC
连接成功，才能把它提升为 runtime-confirmed。设备上的完整行为回归仍待完成。

## 2. “打开全屏工作区”

code-confirmed via `MacWSHost/main.m`：旧按钮直接调用
`requestSceneSessionActivation` 创建第二个 iPadOS Scene，因此它不可能把用户
正在操作的窗口变为全屏工作区。

现在按钮先用现有 `CGWindowID + owner PID` 激活当前 macOS 窗口，然后在同一
`UIWindowScene` 中：

1. 释放精确窗口订阅；
2. 清除单窗身份和尺寸状态；
3. 改订阅 `MacWSStreamModeFullscreen`；
4. 持久化同一 Scene 的 workspace restoration activity；
5. 隐藏控制中心并保留当前应用为 macOS 前台应用。

这还只解决“当前 Scene 内容被换成工作区”，不能冒充 iPadOS 台前调度的系统
最大化。对目标 20D67 UIKitCore 的只读反汇编进一步得到：

```text
-[UISceneActivationRequestOptions _requestFullscreen]:
    ldrb w0, [x0, #0x9]
    ret
-[UISceneActivationRequestOptions _setRequestFullscreen:]:
    strb w2, [x0, #0x9]
    ret
```

RE-confirmed via 目标 DeviceSupport 的
`UIKitCore:0x18a166598-0x18a1665a4`。同一实际二进制中的
`-[UIApplication requestSceneSessionActivation:userActivity:options:errorHandler:]`
在 `0x189de13a8-0x189de13b0` 把 activation options 与 target session 一起交给
`initialClientSettings:activationOptions:targetSession:`。因此 Host 现在对**当前
session** 发送真实 `UISceneActivationRequestOptions`，并置
`_requestFullscreen=YES`；不存在该 selector 时只记录 unsupported，不崩溃，也不
用 CALayer 拉伸伪装最大化。这个入口与系统布局事务的连接是 RE-confirmed；目标
设备是否接受当前 active session 的最大化请求仍是 runtime-pending。

此前全显示器 `CGDisplayStream` 在 `WindowServer -virtualonly` 下能 start 但没有
首帧，因此完整桌面没有继续依赖这条已证伪的 producer。新 producer 创建主显示器
物理像素尺寸的有界 Retina IOSurface 底层，再枚举完整 on-screen `CGWindowList`，
把最多 48 个可见桌面元素/应用窗口分别通过真实
`SLSHWCaptureStreamCreateWithWindow` 捕获。Host 复用单窗已验证的 IOSurface
lease + Metal 多层合成路径，按 CGWindow 的前后顺序组合完整桌面，无 RFB、无
压缩、无 CPU 像素拷贝。该 producer/consumer 已通过 macOS 与 iOS Theos 编译；
设备可见画面仍标记为待回归，不能把编译通过写成 runtime-confirmed。

## 3. VSCode `...` 弹层点击

code-confirmed via `libmachook/AppInputBridge.m`：原子触摸点击对普通 NSWindow
会先发送 `mouseMoved`，再发送 `leftMouseDown/leftMouseUp`，用来建立 AppKit/
Electron 的 tracking-area hover 状态；但条件明确排除了
`routedToTransientWindow`。**THEORY**：VSCode 的 `...` 弹层属于已被多层
DisplayStream 捕获、并被输入路由解析为 transient 的更高 level NSWindow，旧条件
使其缺少 Electron Views 需要的 hover 前导；需要以新运行日志中的最终 window ID
和实际项目动作来确认。

修复后，只把正在运行的原生 AppKit menu tracker 作为排除条件。普通基础窗口和
Electron transient window 都在最终解析出的真实 NSWindow 坐标上收到完整的
`hover -> down -> up` 语义。窗口路由、AppKit hit testing、enabled 状态和动作
派发仍由应用处理，没有按 VSCode 坐标或按钮名称硬编码。新 dylib 已构建、签名并
安装；实际菜单项选择尚待设备 GUI 回归。

## 4. Terminal 滚动/输入闪烁与延迟

旧 Host 日志证明同一个 surface sequence 会被重复提交：

```text
display-perf stream=18 sequence=240 ... receipt-to-submit-ms=0.714 ...
display-perf stream=18 sequence=240 ... receipt-to-submit-ms=78.925 ...
display-perf stream=18 sequence=240 ... receipt-to-submit-ms=351.530 ...
```

runtime-confirmed via `/var/mobile/Library/Logs/MacWSHost.log:13840-13843`。
同样，单次 UI 活动后窗口目录曾在约一秒内广播 16 次：

```text
1785524822.751 display-stream window-list count=1
...
1785524823.666 display-stream window-list count=1
```

runtime-confirmed via 同一日志 `14186-14201`。

对应的、已被日志证明的上游无效工作现已收敛；它们是否是全部可见闪烁的原因仍是
THEORY，必须由新输入到可见画面数据验证：

- `targetPID` 没改变时不再刷新 presentation policy/重画旧 IOSurface；
- 帧状态标签不再包含每帧变化的 sequence，因此 `publishStatus` 去重能阻止每帧
  UILabel 更新与布局；帧序号继续保留在低频 performance 日志中；
- 原生 UIKit 指针在 1x 移动时不再重呈现不变的 macOS surface，只有实际移动放大
  viewport 才请求 Metal draw；
- 16 ms 合并同一个 AppKit 动作产生的 focus/key/metrics 窗口目录失效风暴；
- 小于一个 macOS logical pixel 的高频滚动量先无损累计，越过阈值或手势结束时
  再发送，避免大量最终为 `(0,0)` 的 AppKit scroll/layout/capture 循环。

以上“旧重复提交和广播”是 runtime-confirmed，“代码不再产生这些明确路径”是
code-confirmed。物理手势的输入到可见画面 p95、主观闪烁是否消失仍需新设备运行
数据，不能从静态编译推断。

## 5. 构建、安全与待验收项

本地 Theos 独立构建已通过：

- `MacWSHost` arm64；
- `macwsdisplayd` arm64；
- `libmachook` arm64 + arm64e。

包含最终 current-session fullscreen 请求的完整 rootless package 也已在本机重新
构建，`packages/com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb` 的 SHA-256 为
`33294f4d67b21257203a7540e3e34bbda8a1feefef55b135501fc54e7dc909e3`；该包尚未
部署到不可达的设备。

设备上本轮完整包编译、打包与安装通过；已安装 deb 的 SHA-1 为
`4ad42a7677fa0e1cb7a2ff73ea0275dbf1983842`。安装后的 Host、displayd 与 chroot
两个 `libmachook` slice 都通过新字符串 witness，chroot `/bin/bash` 输出
`chroot-smoke-ok`。当前-session `_requestFullscreen` 是设备随后不可达后才完成的
本地 RE 与代码修改，不在上述已安装 deb 中；不能把该 SHA 当成这项最终改动的设备
witness。生产启动没有被强行继续：watchdog 明确拒绝为：

```text
[macos_gui] ERROR: mandatory health watchdog failed to arm.
启动时系统可用内存仅 58%（安全下限 58%），已拒绝启动 macOS GUI
```

生产启动在初始采样 58% 时被拒绝并完成 GUI 清理；之后进行只读 UIKitCore/
SpringBoard 逆向时 SSH 才不再可达。本轮从未执行 reboot、respring 或
SpringBoard/设备重启。无法从网络不可达本身判断是 Wi-Fi/睡眠还是系统状态变化。
因此没有绕过护栏做一次看似成功但可能导致重启的 GUI 测试。待设备重新可达且可用
内存自然高于 58% 后，使用 production/no-VNC 依次验收：

1. VSCode Open File panel 出现、选取和取消均能结束；
2. 当前 Scene 原地进入完整桌面、系统 geometry 最大化，原应用仍为前台；
3. VSCode `...` 中顶部、中部、底部项目均可点击并关闭弹层；
4. Terminal 连续输入与长文本滚动，记录 capture→receipt、receipt→submit、
   submit→complete 和输入到可见画面 p50/p95；
5. GUI 停止后确认 WindowServer、Host、displayd RSS 和系统可用内存恢复。

本轮没有新增 flag 文件或环境变量；AGX native、production、温控和内存 watchdog
的默认开关状态均未改变。
