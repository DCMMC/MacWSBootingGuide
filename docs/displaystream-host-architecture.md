# MacWS Host 多窗口、显示与触屏交互总方案

> 目标平台：iPadOS 16、台前调度、macOS 13.4 chroot。
> 设计优先级：触屏体验 > 妙控键盘体验 > 兼容性回退。
> 文档状态：2026-08-04；单窗/完整桌面 IOSurface 直传、瞬态窗口分层合成、原生输入、Carbon 右键菜单选择、Ventura 原生 `NSOpenPanel`、当前 Scene 的真实系统全屏以及 Finder/Dock/Launchpad/SystemUIServer/ControlCenter Aqua 工作区均已在目标 iPad 运行确认。Launchpad 已由空数据库恢复为 63 个应用，System Settings 已运行真实 Appearance ExtensionKit 页面，Maps 已通过持续存活的 UIKit carrier 与 UIKitSystem/FrontBoard 身份链冷启动并显示原生窗口；证据见 [`catalyst-system-apps-20260804.md`](catalyst-system-apps-20260804.md)。全屏冷恢复的实时证据为 `status-hidden=YES`、`home-indicator-auto-hide=YES`、Scene bounds 等于 screen bounds；Dock/Launchpad 与右上角 Control Center 点击也有可见状态变化证据。四窗与完整性能门槛仍单列为未完成。

## 一、方案总览

### 1. 产品目标

把 macOS 应用的每个顶层窗口映射为一个独立的 iPadOS `UIWindowScene`，让用户用台前调度同时组织最多四个 macOS 窗口。画面采用 DisplayStream → IOSurface → Metal 直传，交互默认针对手指设计，同时完整保留妙控键盘的指针和键盘效率。

这个产品不是远程桌面皮肤，也不是把整个 macOS 桌面缩小后塞进 iPad 窗口；iPadOS Scene 是一等窗口，macOS `NSWindow` 是它背后的应用窗口。

### 2. 核心工作与原理

| 核心工作 | 非常简要的工作原理 | 当前状态 |
|---|---|---|
| DisplayStream 直传 | SkyLight 窗口流产生 IOSurface，XPC 只传 Mach right 和描述符，Host 直接创建 Metal texture；完整桌面按真实窗口目录分层合成 | 精确基础窗、同 owner 瞬态层和 2388×1668 完整 Aqua 桌面均已在 iPad runtime-confirmed |
| macOS 窗口 → iPadOS Scene | 每个 Scene 保存当前真实 `CGWindowID`、owner PID 和稳定逻辑窗口组，独立订阅、恢复和释放；新 macOS 顶层窗口稳定后自动请求一个新 Scene；工作区复用当前 Scene 并调用 SpringBoard 自己的全屏 action 17 | 新窗口目录 1→2 后自动创建 Scene、精确 FBS Scene 系统全屏、iOS 状态栏隐藏与 Home Indicator 自动隐藏均已 runtime-confirmed |
| 台前调度密集尺寸与初始大小 | SpringBoard `Chamois` 保存可选宽高数组；参考 TrollPad 增加候选档位。新 Scene 再以真实 macOS frame 为建议尺寸，走 `SBMutableSwitcherTransitionRequest → SBMainWorkspace` | 密集网格已 runtime-confirmed；精确 Scene 初始尺寸事务为 RE-confirmed、已实现和部署，待 v6 自然装载后验证小面板尺寸 |
| 比例稳定显示 | 1× 始终完整等比；重排交接期允许短暂边距，不拉伸、不裁边 | 已实现并有纯 C 单测 |
| 小窗口保护 | AppKit 发布窗口真实最小尺寸；Scene 小于要求时整窗遮罩并停止向该窗口注入输入 | 已实现；iPad 待验证 |
| 触屏/键鼠双密度 | 改变 Scene 对应的 macOS 逻辑窗口尺寸，让触屏模式控件更大、键鼠模式信息更多 | 已实现；iPad 待验证 |
| 缩放与精确操控 | 双指双击在 1× 与用户配置的 1.5×/2× 间切换；放大后默认移动视口，输入坐标同步映射到裁剪后的源纹理 | 已实现并有数学单测；原生 magnify 待验证 |
| 直接触控与触控板 | 单指可直接点控；也可把玻璃当相对触控板；妙控键盘指针始终保持绝对坐标；全桌面按真实 CGWindow 前后顺序逐点选择 owner | 原生协议语义矩阵、60 Hz 拖动、Carbon 右键菜单、Dock/Launchpad 和 ControlCenter 点击、滚动压力已在 iPad 通过；真实手指主观手感继续回归 |
| 全屏桌面手势 | 全屏工作区的屏幕虚拟触控板识别三指方向手势，发送一次性 macOS 桌面命令；外接妙控板保留 iPadOS 系统三指手势 | 规划；桌面命令路径与设备输入边界待验证 |
| Scene 顶部菜单栏 | 从目标 AppKit 进程同步 `NSMainMenu` 语义；触屏采用“紧凑可读 → 首次点击展开 → 第二次点击执行”，键鼠保持紧凑桌面逻辑 | 精确 PID/window、generation 快照和动作桥已实现；macOS 外观、hover/键盘导航与复杂菜单仍待完善 |
| 剪贴板、图片与文件 | iOS 与 macOS 之间通过有界 XPC 协议同步文本/图片并暂存文件，使用 generation 防回环 | 已实现；权限与拖放待验证 |
| 性能与稳定性 | 每个基础/瞬态 producer 独立最多三帧在途，Metal 完成后才释放 surface；慢消费者丢新帧而不阻塞 WindowServer | 输入约 60 Hz/亚毫秒；120 次滚动压力中最后一帧 capture→Metal complete 约 10.0 ms、drop=0，完整可见响应和四窗仍待验收 |

### 3. 端到端结构

```text
macOS 应用进程
  ├─ NSWindow / NSApplication
  ├─ AppInputBridge：真实最小尺寸、原生重排、应用内输入
  ├─ 菜单桥：NSMainMenu 语义快照、generation 校验、原动作执行
  └─ metrics.<pid>.bin（低频控制面）
             │
             ▼
macwsdisplayd（macOS 13.4 chroot）
  ├─ 窗口目录：CGWindowID + owner PID + logical group + AppKit 最小尺寸
  ├─ 全屏：Retina IOSurface 底层 + 完整 on-screen SkyLight 窗口目录
  └─ 单窗：精确基础窗口 + 同 owner 菜单/弹窗/Sheet 各自的
           SLSHWCaptureStreamCreateWithWindow
             │ IOSurface Mach right + 帧描述符；无 RFB 编解码
             ▼
MacWSHost（iPadOS）
  ├─ 一个 macOS 窗口对应一个 UIWindowScene
  ├─ 多个 IOSurface → 多个 MTLTexture → 按 SkyLight level 合成到 MTKView
  ├─ 等比视口、缩放、遮罩、密度选择
  └─ Scene 顶部语义菜单 / 触摸 / 全屏桌面手势 / 妙控键盘 / 拖放 / 剪贴板
             │ 84-byte v4 有版本输入记录
             ▼
macwsinputd → 精确 owner PID → AppInputBridge → 目标 NSWindow
```

### 4. 关键产品原则

1. 不用黑边掩盖不兼容。Scene 小于应用要求时明确告知用户，画面和点击都不可继续，避免“看得见但无法正确使用”的假成功。
2. 不绕过 AppKit 约束。最终窗口尺寸必须由应用自己的 `minSize`、`contentMinSize` 和 style mask 决定；Host 只能提出请求。
3. 缩放只改变视口，不改变应用状态。恢复缩放是可预测、无损的本地操作。
4. 密度切换要求 macOS 应用真正重排。不能只把同一张图缩放，否则文字会糊、命中区域也不会改善。
5. 直传失败必须可观察。mmap/VNC 只是诊断和兼容路径，不能静默伪装成 IOSurface 直传。
6. 进程存活不是稳定性证据。帧序号、完成回调、输入结果、内存上界和可见画面才是证据。

## 二、产品交互设计

### 1. Scene 与 macOS 窗口的关系

- “新建窗口”面板列出当前可捕获的 macOS 顶层窗口。
- 选择后创建一个新 `UIWindowScene`，Scene 的 `NSUserActivity` 持久化当前 `CGWindowID`、owner PID、稳定逻辑窗口组、最小尺寸、是否可缩放以及显示密度。
- AppKit 的标签页是多个 `NSWindow`，选中标签会更换前台 `CGWindowID`。AppInputBridge 从真实 `NSWindowTabGroup` 发布稳定逻辑组；一次输入完成后 Scene 刷新小型窗口目录，并在旧 ID 离屏时改订阅同 owner/组的前台成员。不能把 capture ID 当成用户窗口身份。
- 全屏工作区使用 `windowID == 0`，用于桌面、全局菜单栏和尚未适配成独立 Scene 的窗口。
- Scene 进入后台时取消订阅；Metal fence 完成后释放所有 IOSurface lease。恢复前不把旧截图当成可交互画面。
- Host 以 `owner PID + logical group`（无 group 时为精确 `CGWindowID`）作为 Scene 身份。重复打开优先激活既有 Scene；连接后若仍发现重复，保留前台优先级最高的一份并销毁其余 Scene，且销毁去重副本时明确保留 macOS 原窗口。
- 启动 allowlist 应用前，hostd 用 `proc_pidpath` 与解析后的 chroot 可执行文件绝对路径做精确身份匹配。已有进程若已发布窗口 metrics 就直接复用；若尚无可捕获窗口则拒绝生成第二个实例并返回明确状态。
- 窗口目录出现新的稳定逻辑窗口组后，Host 自动请求一个新 Scene。runtime-confirmed via `MacWSHost.log`：Terminal 窗口目录从 1 增加到 2 后出现 `window-auto-scene identity=25808:g:21`、`scene-activation requested` 和 `scene-connected ... window=21`。这条路径按 owner/group 工作，不按应用名 hardcode。
- Scene activation 只能携带系统的离散 preferred size category，不能表达任意 `CGSize`。Host 因此把新 macOS 窗口的真实 frame size 与精确 FBS Scene ID 写入短期请求；SpringBoard tweak 找到该 Scene 对应的 `SBDisplayItem`，沿系统 immutable app-layout transaction 提交建议尺寸。小工具面板可以请求接近真实小尺寸，最终仍由系统边界、网格和应用最小尺寸钳制。

#### 当前 Scene 的沉浸式全屏

“打开全屏工作区”不是创建第二个 Scene，也不是把当前 Metal layer 缩放到窗口边缘：

1. Host 把**当前** Scene 从单窗流切换为完整桌面流并保留同一 session。
2. Host 用 `-[UIScene _sceneIdentifier]` 取得精确 FBS ID，写入 15 秒内有效的一次性请求。
3. SpringBoard 从 switcher content controller 取得真实 keyboard-focused app layout，验证其中包含请求的 bundle 与精确 FBS Scene ID，然后调用系统 `performKeyboardShortcutAction:0x11`。焦点若已变化就有界重试后拒绝，绝不放大别的应用。
4. SpringBoard 自己完成 Chamois/app-layout 转换与动画；Host 同时在桌面流模式返回 `prefersStatusBarHidden=YES`、`prefersHomeIndicatorAutoHidden=YES` 并延迟四边系统手势，形成视频/游戏式沉浸显示。
5. 1.5 秒后以真实 `UIWindowScene.isFullScreen` 和 Scene/screen bounds 作为结果证据。通知送达或进程存活本身不算成功。
6. 全屏是可逆的 Scene presentation state。进入前保存精确 window/PID/logical group、AppKit 尺寸约束、Scene 尺寸和标题；同一按钮第二次触发时恢复同一窗口流并通过真实 app-layout resize transaction 请求原 Scene 尺寸。返回点写入 `NSUserActivity`，进程被 UIKit 回收后也不能变成单向切换；全屏 Scene 被关闭时仍按返回身份关闭对应 AppKit 窗口。

全屏只显示完整桌面流中的 macOS 原生菜单栏；Host 的单窗语义菜单栏高度收敛为 0。控制中心入口是独立的右上角半透明材质按钮，不依赖语义菜单栏；展开面板使用跟随 macOS 浅/深主题的实色 `systemBackgroundColor`，避免固定 dark blur 与动态标签/填充混色。

RE-confirmed via 20D67 SpringBoard `-[SpringBoard _handleEnterFullScreenKeyShortcut:]` `0x1c7669808`：系统从 active display window scene 取得 switcher controller，并执行 action `0x11`（十进制 17）。runtime-confirmed via `MacWSWindowing.log`：目标 Scene 首次尝试即 `exact-focus=YES`、`action=YES`，随后记录 `fullscreen-performed ... action=17`。Host 冷恢复又在 0/250/1250 ms 三次记录 `status-hidden=YES`、`home-indicator-auto-hide=YES`、`deferred-edges=15` 以及 Scene/screen bounds 均为 1389×970；像素截图未出现 iOS 状态栏或 Home Indicator。

全屏桌面输入不绑定一个永久 owner。指针、触摸与滚动以 `targetPID=0` 进入 `macwsinputd`，由 `CGWindowListCopyWindowInfo` 的真实前后顺序逐点选择第一个包含该点的非 WindowServer、非负层窗口。这样普通应用窗口、AppKit 弹出层、Dock/Launchpad 以及 SystemUIServer/ControlCenter 状态项走同一中央算法。runtime-confirmed：Launchpad 点击命中 `owner=Dock layer=27 window=25` 并改变文件夹展开状态；右上角点击打开了真实 macOS Control Center。完整证据见 [`fullscreen-aqua-workspace-20260802.md`](fullscreen-aqua-workspace-20260802.md)。

#### 台前调度尺寸档位突破

iPadOS 16 的固定尺寸档位不是本方案必须接受的产品边界。开源项目 [TrollPad](https://github.com/khanhduytran0/TrollPad) 已包含直接证据：其 SpringBoard tweak hook `SBSwitcherChamoisLayoutAttributes` 的 `setGridWidths:` 和 `setGridHeights:`，把系统传入的少量候选值替换为从 150 point 起、每 20 point 一档的密集数组。参考实现见不可变的 [TrollPad 1.3 `TweakSB.x` 第 145–166 行](https://github.com/khanhduytran0/TrollPad/blob/1.3/TweakSB.x#L145-L166)；功能由提交 [`bc31c3a`](https://github.com/khanhduytran0/TrollPad/commit/bc31c3a7344576cfa7bb6a6db3136578e0f094ee) 引入并进入 1.3 正式版，README 明确把 Stage Manager 标为 iOS 16 及以上能力。

目标 `iPad13,6 / iPadOS 16.3.1 (20D67)` 的真实 SpringBoard 二进制进一步确认：该版本确实包含这个类、两个 setter、宽高数组 ivar，以及逐项寻找最接近请求尺寸的 `_nearestGridSizeForSize:gridWidths:gridHeights:bounds:`。因此“iPadOS 16.3.1 可以把少量系统档位扩展为密集离散档位”是 RE-confirmed，不再只是第三方源码推断。它仍不能自动证明 tweak 已在当前关机设备上成功注入，也不等于逐 point 连续自由缩放已经成立。正式实现采用以下边界：

- 第一阶段增加密集档位，不绕过最终 geometry 校验，不用 CALayer transform、截图裁剪或伪造 `UIWindowScene.bounds` 形成假窗口。
- TrollPad 的 150 point 下限和 20 point 步长是参考实现参数，不是 MacWS 已确认的安全常量。目标值由设备原始候选数组、系统标题栏/safe area、AppKit 最小尺寸和运行稳定性共同确定。
- 直接 hook 上述两个 setter 会改变全系统台前调度候选数组。MacWS 专用策略需要继续追踪具有 Scene/application identity 的候选选择或 geometry 提交层；在找到该层前，不能声称现有 hook 已能按 bundle/Scene 隔离。
- 若先提供全局实验开关，必须默认关闭、可从安全模式恢复，并保证所有生成值 finite、单调、在显示边界内且保留系统原始最大档位。
- 产品优先采用 16–20 point 的密集档位。只有密集档位仍明显妨碍使用时，才继续研究逐点连续缩放；连续拖动同样必须落到真实 Scene geometry，而不是把旧 surface 作为最终画面拉伸。
- Scene 尺寸变化可以连续反馈给 Host，但传向 AppKit/DisplayStream 的重排请求必须合并和防抖；拖动结束再提交一次最终精确尺寸，避免 resize storm 和 IOSurface 池反复重建。
- 新档位低于 macOS 应用要求时，沿用下一节的整窗遮罩和输入冻结；不得为了“支持小窗口”绕过 AppKit 最小尺寸。

### 2. 小尺寸窗口：整窗遮罩

判定公式：

```text
像素匹配密度 = macOS surface backingScale / (MTK drawable pixels / Scene points)
像素匹配所需 iPad 宽高 = macOS 最小 frame 宽高 × 像素匹配密度
放大 +10% 所需 iPad 宽高 = macOS 最小 frame 宽高 × 像素匹配密度 × 1.10
更多空间所需 iPad 宽高 = macOS 最小 frame 宽高 × 像素匹配密度 × 0.85
```

只要 Scene 的可用宽度或高度低于当前模式要求：

- 用接近不透明的系统背景覆盖整个渲染区域；不显示黑边和被挤坏的 macOS UI。
- 文案同时显示应用要求、当前模式要求，并引导“放大 iPadOS 窗口”或“切换更多空间”。
- 禁止该 Scene 的触摸、指针和键盘注入，防止用户在不可见位置误操作。
- 保留 Host 控制面板入口，用户仍可切换密度、选择其他窗口或进入全屏工作区。
- 当窗口重新达到要求时自动撤去遮罩，并按 33 ms geometry 合并策略向 AppKit 请求重排。

如果最小尺寸尚未从应用进程发布，协议中的值为 0，含义是“未知”，不是“没有最小尺寸”。Host 不猜一个全局常量；AppKit 仍会钳制实际 resize，下一次窗口目录刷新后再做遮罩判定。

### 3. 正常显示：始终保持宽高比

- Host 让 macOS 窗口按 `SceneSize / densityScale` 重排，使新 IOSurface 与 Scene 收敛到同一宽高比。
- UIKit 会先提交 Scene geometry，AppKit 和 DisplayStream 随后才产生新尺寸的 IOSurface。在这段有界交接期，上一帧必须用 aspect-fit 保持完整比例；允许短暂出现边距，但禁止把旧帧拉伸成新比例，也禁止裁掉标题栏和窗口边缘。
- Metal 的目标矩形按当前 drawable 的物理像素网格取整，避免原生 Retina 模式仍落在半像素边界上。
- 新 IOSurface 到达后重新计算显示、输入和悬浮指针的同一组变换。持续边距说明 AppKit 重排没有收敛，必须作为 resize 故障暴露，不能用永久拉伸掩盖。

### 4. 双指缩放、移动与恢复

- 只保留两个稳定状态：1× 和一个用户配置的放大倍率。设置中可选 1.5× 或 2×，不提供连续缩放和多个临时档位。
- 双指双击：在 1× 与配置倍率之间切换。进入放大时以双击位置为锚点；再次双击或点击控制面板“退出放大视角”会恢复 1×，中心点回到 `(0.5, 0.5)`。
- 1× 下双指滑动：发送 macOS 横向/纵向 pixel scroll，照片、网页、时间线等内容保持桌面应用原有的滚动语义。
- 放大后双指滑动：默认移动 Host 的放大视口。画面上显示短小 HUD，可显式切换“移动视图 / 操作内容”；选择“操作内容”时双指滑动继续发送 macOS scroll。
- 第二根手指加入时，Host 先取消尚未判定的单指候选；若左键拖动已经开始，则发送 cancel，避免 macOS 留下卡住的 mouse-down。
- “操作内容”当前只解决双指滑动的路由，并不等于已经支持照片/浏览器的原生 magnify。不能通过应用白名单猜测手势归属。
- 右键菜单内容超出单窗捕获范围时不做自动缩放或迁移，这是明确的非目标。

**原生双指缩放的证据边界**

- 本地开发机 runtime-confirmed（macOS 26.3.1，非目标 13.4）：`NSEvent.magnification` 是只读属性，公开 API 没有 magnify gesture 的构造器；用 `otherEventWithType:NSEventTypeMagnify` 构造会抛出 `NSInternalInconsistencyException`，原因是该类型不属于允许的 weird-event mask。
- 因此当前实现不伪造 `NSEventTypeMagnify`，也不把滚轮事件包装成“原生 pinch”。目标 macOS 13.4 上需要继续 RE AppKit/IOHID 的真实 gesture event 路径，并用 Photos/Safari 的运行日志或断点证明 begin/change/end 与 magnification 数据完整到达后，才能把它接入 HUD 的“操作内容”模式。

### 5. 显示密度与 macOS DPI

macOS 的显示缩放主要是显示级配置，并不适合在四个独立 Scene 之间频繁切换全局 DPI。单纯修改 `backingScaleFactor` 也不是可靠的公开逐窗口 API，而且可能破坏 SkyLight、Core Animation 和输入坐标的一致性。

当前实现采用“逐窗口有效密度”：

- **像素匹配 Retina（默认）**：动态使用 `macOS backingScale / UIKit effectiveDrawableScale`。最终安装二进制的 runtime witness 为 `frame=1728x1302 backing=2.000 drawable=1726x1302 content=(0.00,0.58 1004.00x755.84) density=1.16`：高度完全相等，宽度差异限制在两个物理取整像素内。同一几何版本还记录过 AppKit 收敛到 `1027x651 logical point`、surface `2054x1302`、drawable `2053x1302` 的一像素差证据。全屏或其他 Scene 合成比例变化后会重新计算，不能把 100% 或 135% 当成所有窗口状态下的固定答案。
- **放大 +10%（可选）**：在动态像素匹配密度上乘 1.10，向 AppKit 请求更小的逻辑窗口，再由 Host 放大到 drawable。它可以让字体和控件变大，但当前仍是 Metal 线性重采样，不是逐像素 Retina；产品文案和默认迁移都不得把它描述成无损 HiDPI。
- **更多空间 +18%**：在动态像素匹配密度上乘 0.85，使逻辑画布扩大约 `1 / 0.85 = 1.176`，再做一次受控等比缩小。它明确是可选缩放，不宣称是 1:1 原生 HiDPI。
- DisplayStream 的真实 `backingScale` 仍用于 HiDPI 像素传输；密度模式不伪造 IOSurface 尺寸。原生 Retina 模式的验收必须记录 surface backing scale、drawable 像素尺寸和最终内容矩形三者，而不能只看控制面板的百分比文案。
- 切换模式会恢复视口缩放、重新计算小窗口门槛，然后防抖请求 AppKit 重排。

因此，这里实现的是“每个 Scene 的有效信息密度”，不是修改 macOS 全局 DPI。真正“字体更大且仍逐像素锐利”需要在 AppKit/Core Animation 上游提高该窗口的 backing scale，并让扩大后的 backing surface 继续精确匹配 drawable；继续增大 Host 缩放系数做不到这一点。将来若验证出 macOS 13.4 可安全逐窗口设置 backing scale，必须先证明窗口纹理、命中测试、菜单和跨屏拖动四者一致，才能替换当前方案。

### 6. 触摸与妙控键盘

**默认直接触控**

- 单指落下先进入候选状态，不立即发送 mouse-down；位置直接对应当前可见纹理中的 macOS 像素。
- 450 ms 内抬起且移动不足 6 pt：发送一个原子左键单击。
- 450 ms 前移动达到 6 pt：进入原生滚动序列，发送 began/changed/ended 和有界惯性；单指滑动因此成为默认页面滚动手势。
- 保持 450 ms 且移动不足 6 pt：只武装左键拖动并触发轻触觉反馈，不提前发送右键。之后移动达到阈值才发送 down/move，抬起发送 up。
- 武装后不移动直接抬起：发送一个原子右键单击。这样长按右键与长按后拖动共享前半段，但不会互相抢占。
- 第二根手指加入会取消候选；若左键拖动已经开始，Host 发送 cancel。这样双指滚动/放大不会留下卡住的按钮状态。
- 适合经过触屏密度放大的按钮、列表、标签页、拖动目标和右键菜单。450 ms 与 6 pt 是产品阈值，设备测试后可以统一调整，不能在各手势回调里复制不同常量。

**精确触控板**

- 单指相对移动鼠标；轻点为原子左键点击；长按后移动为拖动。
- 双指轻点为原子右键；双指移动发送横向和纵向 pixel scroll。
- Host 在 macOS 内容上持续显示一个 iPadOS 风格的圆形材质指针；按住时收缩，Scene 改尺寸或旋转时使用与画面相同的变换重新定位。
- 右键 down/up 在一个数据报内表达，避免拥塞时 up 越过 down。

**妙控键盘**

- 间接指针/hover 始终走绝对坐标，不因当前手指模式而改成相对移动。
- USB HID usage 映射为 macOS keycode，同时保留字符、修饰键、方向键、功能键和组合快捷键。
- 软键盘与硬键盘共享同一个目标窗口和 owner PID；Scene 遮罩或流未就绪时都不能注入。
- 硬件键盘出现不应强制切换密度，以免用户正在触控时布局跳动；控制面板显式选择并持久化模式。后续可提供一次性建议，而不是自动改动。

**浮动键盘与快捷键栏的布局边界**

- iPad 浮动软件键盘由用户拖动，不参与 macOS 内容避让；Host 不绑定 `keyboardLayoutGuide`，也不因浮动键盘 frame 改变而 resize macOS 窗口。
- `Ctrl / Option / Command / Shift / Esc / Tab / 方向键` 是 Host 自己的 52 pt 底部快捷键栏。只有该栏显示时，Metal 内容的底边约束到快捷键栏顶边，真实减少内容高度；收起后高度恢复为 0。
- 快捷键栏不是 `inputAccessoryView`，不会覆盖 Metal 内容。触摸 Metal 时若键盘输入代理仍激活，不抢走 first responder，避免浮动键盘刚弹出又自动关闭。

**全屏工作区的三指桌面手势**

- 只在 `windowID == 0` 的全屏工作区启用；单窗 Scene 中三指不改变 macOS 桌面，避免与台前调度窗口组织和应用自身手势混淆。
- 正式支持目标首先是“iPad 屏幕作为虚拟触控板”的三根直接触点：三指上滑 → Mission Control，三指下滑 → App Exposé，三指左/右滑 → 切换 macOS Space。三指轻点 → 显示桌面作为默认关闭的可配置动作。
- 手势只发送一次语义桌面命令，不把三根触点转译成高频鼠标事件，也不向当前应用留下 down/cancel 状态。
- 第三根手指加入时，先取消尚未判定的单指候选和双指滚动；若左键拖动已经开始则发送 cancel。只有三指同时落在 Metal/虚拟触控板区域内才可进入候选，菜单栏、软键盘、控制面板和系统边缘区域不参与。
- 达到方向/距离/速度阈值后锁定一个轴并只触发一次；识别过程中显示半透明 HUD，成功时给轻触觉反馈，未达阈值抬起则无副作用。具体阈值必须集中在纯策略函数并由 iPad 手感测试决定。
- macOS Mission Control、App Exposé、Space 和显示桌面的执行必须走独立桌面命令控制面；不能伪造成发送给某个前台应用的普通鼠标事件。实际 SkyLight/Dock/系统快捷键路径尚未 RE/runtime-confirmed，未确认前均为产品目标，不得标记已实现。

iPadOS 的三指左/右滑撤销/重做属于 UIKit 标准编辑交互，应用可以在当前 responder 上显式退出，不必把屏幕中央的横向桌面手势永久标为实验功能。Apple 在 iOS 13 的 UIKit 说明中给出的控制点是 `UIResponder.editingInteractionConfiguration`：<https://developer.apple.com/videos/play/wwdc2019/224/>。

```objc
- (UIEditingInteractionConfiguration)editingInteractionConfiguration {
    return self.fullScreenDesktopGestureMode && !self.softKeyboardActive
        ? UIEditingInteractionConfigurationNone
        : UIEditingInteractionConfigurationDefault;
}
```

- 只由全屏 `MacWSMetalView` 在桌面手势模式下返回 `None`，让自定义三指 pan 拥有左右方向；设置页、文件选择器、Scene 语义菜单等普通 UIKit responder 保持 `Default`。
- `editingInteractionConfiguration = None` 只关闭当前 responder 的 UIKit 编辑手势，不代表取得 iPadOS 边缘导航、辅助功能或外接妙控板系统手势的所有权。
- 软键盘显示或隐藏 `UITextInput` 代理成为 first responder 时，禁用桌面三指 recognizer，并让输入代理保持 `Default`；键盘收起且 Metal View 恢复 first responder 后再启用。不能让一次横向 Space 切换同时对输入代理执行 undo/redo。
- responder、软键盘、菜单和 Scene 状态切换必须通过一个统一策略更新 recognizer enabled 与 editing configuration，不能由多个通知各自修改一半状态。
- 三指 pinch 仍保留给 UIKit copy/paste，不纳入桌面命令；当前只接管三指方向 pan。

外接 Magic Trackpad/妙控键盘触控板必须单独处理。Apple 的 iPad 使用说明把三指上滑定义为 Home/应用切换器、三指左右滑定义为切换 iPad App；因此方案默认这些手势由 iPadOS 所有，不尝试私有 hook 抢占系统导航：<https://support.apple.com/guide/ipad/ipad66ce6358/ipados>。

- UIKit 可以区分 indirect pointer 输入并对部分触控板 gesture recognizer 作响应，但这不能证明 iPadOS 会把系统三指手势的原始触点交给本应用：<https://developer.apple.com/documentation/uikit/pointer-interactions>。
- 设备验证若确认某个三指事件能稳定到达 Host，可作为可选映射启用；验证前不能让 UI 暗示它可用。
- 外接妙控板的可靠替代方案预留为“Control + 双指上/下/左/右滑”，对应同一组桌面命令；修饰键可配置，且不得覆盖普通双指滚动。键盘还保留直接快捷键入口。
- 若桌面命令后端不可用，Host 明确显示“桌面手势不可用”，不能静默改为 iPadOS 切 App、Host 自制总览或向当前应用发送近似按键。

### 7. 菜单栏

菜单栏放在每个 iPadOS Scene 内容区的 safe area 顶部，不替换、覆盖或依赖台前调度自己的系统标题栏。它不是从 macOS 全屏画面裁剪出来的位图，而是目标应用菜单语义的 UIKit 表达；否则会产生错误焦点、错误 enabled/state、模糊文字和不可访问的子菜单。

**两阶段触屏布局**

- 紧凑显示态固定占用约 26–30 pt，字体约 12–13 pt；目标只是清晰可读，不要求把每个标题画成常驻大按钮。Metal 内容从紧凑栏下方开始，避免覆盖 macOS 标题栏。
- 视觉标题可以紧凑，但命中区域按相邻标题中线分割并覆盖标题间空白。用户点击“文件”附近即可选中“文件”，不必精确点击字形。
- 第一次点击只选择顶层分类并展开，绝不执行菜单命令。菜单栏以点击标题为锚点，在约 150 ms 内切换为稀疏触摸态。
- 展开后顶栏约 48–52 pt，菜单项行高约 44–48 pt；文字、勾选、快捷键和层级标记同步使用触屏尺寸。
- 第二次点击才执行菜单项。这样即使第一次命中邻近标题，也只有分类展开，不会误触破坏性命令。
- 展开层覆盖在 Metal 内容上，不改变 Scene 的稳定内容尺寸、不触发 macOS 窗口 resize，也不改变当前 1×/放大视口。
- 点击画面空白、再次点击当前标题、按 `Esc`、Scene 失焦/后台化、旋转或台前调度尺寸变化时收起。展开状态不跨 Scene 恢复。
- 在展开态横向滑过其他标题可直接切换分类。子菜单在同一面板内推进并提供返回/面包屑，不采用容易越出 Scene 的桌面横向级联菜单。
- 菜单内容超过可用高度时只让菜单面板内部滚动，最大高度受 Scene safe area 约束；不能扩大 iPadOS 窗口或裁剪到相邻 Scene。

**窄窗口和遮罩状态**

- 台前调度窗口过窄时降级为“应用名 / 文件 / 编辑 / 更多…”，`更多…` 打开完整分类列表；不能把不可见标题留在屏幕外。
- macOS 内容因最小尺寸不足而显示整窗遮罩时，紧凑菜单栏和 Host 控制入口仍保持可用，允许用户执行关闭窗口、偏好设置等操作。
- 语义菜单弹出层不受“右键菜单超出单窗 capture 范围无需支持”的限制，因为它是 Scene 内 UIKit 视图，不依赖窗口纹理捕获。

**妙控键盘与指针**

- 键鼠模式保持紧凑菜单栏；指针点击直接打开普通密度菜单，不进入触屏放大动画。
- hover 可在顶层分类之间切换；方向键、Enter、Esc 和 macOS 原快捷键必须继续工作。
- 输入模式由 Host 当前直接触控/触控板设置决定，不因一次偶然 pointer event 改变菜单布局，避免界面来回跳动。

**语义与动作一致性**

- 第一次点击时先激活该 Scene 对应的精确 owner PID 和 `NSWindow`，再由 AppInputBridge 在应用主线程读取最新 `NSMainMenu`。
- 快照包含标题、层级、enabled、state、分隔线、快捷键和本 generation 内有效的 opaque item ID；不能把 ObjC 指针或 selector 当跨进程稳定标识。
- 选择项目后发送 owner PID、window ID、generation 和 item ID。目标应用必须在主线程重新定位菜单项、再次验证 enabled/state，然后通过 AppKit 原菜单动作路径执行。
- generation 过期、窗口不再是目标、菜单项消失或 disabled 时拒绝执行并刷新面板，不能对旧快照“尽力执行”。
- 紧凑态只缓存低频顶层标题；第一次点击立即播放本地展开动画，同时请求被选分类的最新子树。这样不需要持续高频同步整棵 `NSMainMenu`，也能用动画覆盖一次控制面往返。
- 第一阶段支持普通项目、分隔线、多级子菜单、enabled、勾选/混合状态和快捷键。`NSMenuItem.view`、Services 等复杂内容显示“在全屏菜单栏中打开”，不能伪装为已兼容。

全屏工作区继续保留真实 macOS 全局菜单栏，作为复杂菜单和调试时的兼容入口。Scene 语义快照、generation 校验和原动作执行桥已经实现；当前顶层标题已使用紧凑的 macOS 风格玻璃栏，但展开面板仍需替换 UIKit alert 外观，并补齐 hover、方向键/Enter/Esc、复杂 `NSMenuItem.view` 和多级菜单的设备矩阵。因此本节的完整交互仍不能标记稳定。

### 8. 剪贴板、图片、文件与拖放

- 文本、PNG、JPEG 通过 XPC inline 传输，单项最多 8 MiB；描述符含 generation、origin 和 SHA-256 截断摘要。
- iPad → macOS 的文件先复制到 `/Users/Shared/MacWS Imports/<UUID>/`，然后作为原生 file URL 写入 NSPasteboard。
- macOS → iPad 的 file URL 经 `/var/mnt/rootfs` 映射，供粘贴、拖出和 share sheet 使用。
- 每次读取 iPadOS general pasteboard 必须由用户动作触发，避免无意触发系统粘贴隐私提示。
- 同一内容由 origin/generation 去重，服务重启后也不得在两端无限回弹。
- 安全作用域 URL 必须在复制完成后成对结束访问；路径需 canonicalize 并限制在允许的 rootfs/暂存目录内。

**macOS 原生打开/保存面板**

- “打开文件”仍由目标 macOS 应用执行自己的 `⌘O` / `NSDocumentController` 动作；Host 不弹 iOS `UIDocumentPickerViewController`，也不复制一个外观相似的 UIKit 文件浏览器。
- RE-confirmed via macOS 13.4 AppKit `-[NSLocalSavePanel _useRemotePanel]`：`NSUseRemoteSavePanel` 默认值决定是否走远程 ViewBridge。chroot 中缺少该远程面板服务，所以生产构造器把 `NSUseRemoteSavePanel` 设置为 `NO`，让 AppKit 自己选择同进程的 `NSLocalOpenPanel → NSLocalSavePanel → NSPanel`。
- runtime-confirmed via 2026-08-02 目标 iPad 可见截图 `/tmp/macws-native-open-panel.png`：Ventura Finder 风格的原生 `NSOpenPanel` 完整出现。实现没有替换 `NSOpenPanel` 类、没有伪造 modal result，也没有 always-YES 校验 hook。

## 三、开发技术细节

### 1. DisplayStream 与 IOSurface 生命周期

全屏路径：

```text
CGDisplayStreamCreateWithDispatchQueue(main display)
  → IOSurfaceRef callback
  → retain + lease token
  → IOSurfaceCreateMachPort
  → XPC
```

单窗路径：

```text
SLSHWCaptureStreamCreateWithWindow(windowID, false, properties, queue, handler)
  → content-shape IOSurfaceRef callback
  → 同一 lease/XPC/Metal 路径
```

Host 路径：

```text
IOSurfaceLookupFromMachPort
  → 校验 width/height/bytesPerRow/fourCC
  → newTextureWithDescriptor:iosurface:plane:
  → Metal command buffer
  → completion handler 中 release_frame
```

约束：

- 每个订阅客户端最多 3 个 outstanding lease。
- 消费者落后时 producer 丢弃新帧并累计 `droppedFrames`，不能阻塞 SkyLight 回调或无限增长内存。
- 畸形描述符、错误窗口 ID、几何不匹配、非 BGRA surface 都必须立即释放对应 lease。
- Scene 后台化或取消订阅时先提交空 command buffer 作为 fence，再释放仍可能被 GPU 采样的 surface。
- 直传路径没有 framebuffer memcpy、`replaceRegion`、RFB 压缩或 RFB 解压。mmap upload 只在 display service 不可用或尚未收到第一帧时作为显式回退。

### 2. 窗口目录与 AppKit 最小尺寸

`AppInputBridge` 每 500 ms 在应用主线程枚举 `NSApplication.windows`，只有内容变化时才原子写入：

```text
/private/tmp/macws_window_metrics.<pid>.bin
```

最小 frame 计算：

- 固定窗口：最小尺寸等于当前 frame，标记为不可 resize。
- 可 resize 窗口：取 `NSWindow.minSize` 与 `contentMinSize + frame decoration` 的逐轴最大值。
- 所有结果检查 finite、正值和协议上限；不能用零内存或固定常量填充未知字段。

`macwsdisplayd` 构建窗口列表时按 owner PID 读取一次 sidecar，再按真实 `windowNumber` 合并。metrics 不进入逐帧热路径。sidecar 缺失或损坏时最小尺寸为“未知”，不会被当成已确认事实。

后续稳定性增强：metrics header 应增加进程启动身份或 audit token witness，防止异常退出后旧 sidecar 遇到 PID 复用。当前启动和析构会清理文件，系统 cleanup 脚本也会删除残留。

### 3. 窗口重排控制面

Host 以 33 ms 合并窗口拖动期间的 Scene geometry，并在 350/1200/3000 ms 三个有界收敛点重申同一最终尺寸：

```text
sceneID  = 精确 CGWindowID 编码
targetPID = 窗口 owner PID
x/y      = Scene 宽高 / densityScale，单位为 macOS logical point
pressure = densityScale
```

`macwsinputd` 只把这一控制记录路由给精确 PID，不构造 CGEvent。`AppInputBridge` 再次核对 window number，在应用主线程读取实时约束，将请求钳制到真实最小尺寸，然后用原生 `setFrame:display:animate:` 重排，并保留窗口顶边位置。

这是一条 AppKit 正常 resize 路径，不是 hook 验证函数、强制分支或跳过约束。任何应用仍可拒绝或重新调整请求；Host 必须以随后发布的窗口目录为准。

### 4. 等比视口与坐标公式

纯函数位于 `include/macws_viewport_math.h`，输入源纹理宽高、Scene 宽高、zoom 和 center，输出规范化 `visibleSource`。

1× 使用完整窗口 aspect-fit；只有用户显式进入 1.5×/2× 放大视角时，纯函数才计算下列有界裁剪视口：

```text
sourceAspect > viewAspect:
    visibleWidth  = viewAspect / sourceAspect
    visibleHeight = 1
否则:
    visibleWidth  = 1
    visibleHeight = sourceAspect / viewAspect

visibleWidth  /= zoom
visibleHeight /= zoom
center 在 [visible/2, 1-visible/2] 内钳制
```

触摸映射：

```text
u = clamp(viewX / sceneWidth,  0, 1)
v = clamp(viewY / sceneHeight, 0, 1)
sourceX = visibleSource.x + u × visibleSource.width
sourceY = visibleSource.y + v × visibleSource.height
frameX = sourceX × IOSurfaceWidth
frameY = sourceY × IOSurfaceHeight
```

Metal 顶点始终覆盖 `[-1, 1] × [-1, 1]`，纹理坐标使用 `visibleSource`。输入和绘制共用同一矩形，不能分别重新计算宽高比。

### 5. 输入 ABI 与路由

- `MacWSInputRecord` 当前为 v4、固定 84 bytes；接收端先校验 magic、version 与完整长度，不能把 v3/v4 数据报混读。
- window Scene 使用 `sceneID` 的 bit 31 作为标记，高 32 位保存完整 `CGWindowID`，低 31 位保留修饰键。
- configure-window 使用 v4 固定记录的 kind 15；旧 v3 接收端不属于兼容目标，必须由版本校验明确拒绝。
- 坐标始终是当前 producer frame 的物理像素，不是 iPad point 或全桌面坐标。
- AppInputBridge 每次事件都根据目标窗口当前 AppKit frame 做转换，不能缓存一个跨 resize 的旧 origin。
- 控制记录、键盘、滚动和指针都先验证 magic/version/finite/范围/owner PID；失败需有可归因日志。

### 6. 桌面命令控制面（规划）

全屏三指手势的输出是低频、一次性的 desktop command，而不是指针 ABI 的连续事件。建议定义固定长度、版本化的 `MacWSDesktopCommandRecord`：

```text
Host gesture recognizer
  → desktop command(kind, sequence, timestamp, source, modifiers)
  → 精确系统控制服务
  → SkyLight / Dock / 已验证系统快捷键路径
  → result(sequence, status, backend)
```

- `kind` 第一阶段只允许 Mission Control、App Exposé、previous/next Space 和 Show Desktop；未知命令必须拒绝。
- 记录包含 magic、version、size、单调 sequence、Mach timestamp、输入来源和修饰键；坐标、触点轨迹和任意字符串不进入协议。
- 后端必须明确报告实际使用的执行路径，且每条路径要有 macOS 13.4 RE 或运行证据。不能在 SkyLight 调用失败后静默注入一组未经验证的快捷键。
- 同一 gesture sequence 最多执行一次；服务断线、超时、重复 sequence 或全屏 Scene 已失焦时拒绝。结果返回前不阻塞 Metal、DisplayStream 或输入接收线程。
- Host HUD 分别显示“识别中 / 已执行 / 不可用”，而不是用动画假装桌面状态已经改变。成功证据是可见桌面/Space 变化和对应 result，不是服务进程存活。
- 第一阶段可以只实现经设备验证的一部分命令；不可用命令从设置中隐藏，并在能力握手中返回明确 bitset。
- Host 侧必须以一个纯策略函数同时决定：是否为全屏、是否有软键盘/输入代理、是否展开菜单、是否处于系统边缘、辅助功能状态、`editingInteractionConfiguration` 返回值和三指 recognizer 是否 enabled。协议层不能修补一个本应在 UIKit responder 层拒绝的手势。

### 7. 菜单快照与动作协议（规划）

菜单是低频、可变长控制面，不能塞进 84-byte v4 输入热路径，也不能为方便而复制未定稿结构体到 Host 和 AppInputBridge。建议单独定义版本化协议：

```text
NSMainMenu
  → bounded snapshot(header + nodes + UTF-8 string table)
  → MacWSHost 当前 Scene
  → action(ownerPID, windowID, generation, itemID)
  → AppKit 主线程重新验证并执行
```

- snapshot header 至少包含 magic、version、总长度、owner PID、window ID、generation、node count 和 string-table length。
- 每个 node 至少包含 opaque item ID、parent ID、同级顺序、flags、state、title range 和 shortcut range；所有 offset/length 必须做溢出与 UTF-8 边界校验。
- 对 node 数、树深、单字符串、总 payload 和单进程缓存设置明确上限；循环 parent、重复 item ID、越界字符串和未知必需 flag 全部拒绝。
- action 使用独立固定长度记录，只表达精确身份和选择，不传 selector、target 地址或任意对象归档。
- Host 只在本 Scene 前台且 owner PID/window 与实时目录一致时接受快照；目标退出、PID 复用、窗口关闭或 generation 回退都使缓存立即失效。
- 展开动画必须本地立即开始；菜单子树响应 p95 目标不高于 100 ms。超时显示可取消的加载态并保留全屏菜单入口，不能冻结渲染或输入线程。

### 8. 协议边界

| 协议 | 版本与固定结构 | 重要上限 |
|---|---|---|
| Stream | window descriptor 64 B；frame descriptor 72 B | 16384 px；256 窗口；64 damage rect |
| Metrics | header 24 B；entry 16 B | 256 entry；原子 sidecar |
| Input | v3 record 52 B | 精确 PID/window；所有 float finite |
| Interop | item descriptor 56 B | 8 MiB inline；32 items；path 4096 B |
| Desktop（规划） | 独立固定 command/result 版本 | enum allowlist；单调 sequence；能力 bitset；一次执行 |
| Menu（规划） | 独立 snapshot + action 版本；结构待实现时确定 | 有界树深/node/字符串/payload；opaque item ID + generation |

协议变更必须：提升相应 version、保留旧端可诊断失败、更新 `_Static_assert`、增加 malformed-length/overflow 单测。不能只修改发送端和接收端之一。

### 9. 场景恢复与失效处理

- `NSUserActivity` 保存 mode、window ID、PID、最小尺寸、resizable、density。
- 恢复后立即重新请求窗口目录；目录中的实时 PID/约束覆盖持久化快照。
- 目标窗口关闭、PID 改变或 AppInput socket 消失时，Scene 显示“目标不可用”，停止输入并允许重新选择。
- surface 序号必须单调；旧 stream/window 的迟到帧释放但不呈现。
- 前后台切换、旋转和台前调度档位变化都必须使未执行的 resize 防抖任务失效。
- Scene 失焦、恢复、目标 PID/window 改变或尺寸变化时收起触屏菜单；持久化层不保存展开菜单、item ID 或旧 generation。
- 全屏 Scene 失焦、后台、旋转或退出全屏时取消三指候选和 HUD；不重放未确认的桌面命令。

### 10. 文件与模块所有权

为避免后续多个 agent 同时改变同一不变量，按下表分工。一次集成周期内，同一行只指定一个 owner；其他 agent 通过协议或测试提交建议。

| 模块 owner | 文件 | 负责的不变量 |
|---|---|---|
| 协议 owner | `include/macws_*_protocol.h`、`include/macws_viewport_math.h`、`include/macws_touch_policy.h` | ABI、版本、上限、纯函数与统一手势阈值 |
| AppKit owner | `libmachook/AppInputBridge.m` | 真实窗口约束、主线程 resize、应用内输入 |
| Display owner | `macwsdisplayd/` | SkyLight/CG stream、窗口目录、IOSurface lease |
| Host owner | `MacWSHost/` | Scene 生命周期、Metal、遮罩、缩放、密度和 UIKit 交互 |
| Input owner | `macwsinputd/` | 记录校验、PID/window 路由、CGEvent/AppInput 分流 |
| Interop owner | `macwsinteropd/`、`MacWSInteropClient.*` | 剪贴板、文件暂存、权限、去重 |
| Menu owner（规划） | 新 `macws_menu_protocol.h`、AppInputBridge 菜单端、Host 菜单视图 | 快照上限、generation、精确窗口、两阶段布局和动作重验证 |
| Desktop owner（规划） | 新 `macws_desktop_protocol.h`、系统控制服务、Host 三指识别器 | capability、一次执行、全屏门控、系统后端证据和结果回执 |
| Windowing owner（规划） | 新 SpringBoard tweak（路径待定）、对应 iPadOS 16 私有头与 probe | Chamois 候选数组、Scene 隔离、geometry 提交、恢复开关与版本门控 |
| Bootstrap owner | `layout/usr/macOS/`、根 Makefile | launchd 顺序、清理、签名、打包 |
| Evidence owner | `misc/`、`docs/evidence/` | probe、基准、日志索引、结果判定 |

建议集成顺序：协议与纯函数 → producer/AppKit → input/interop → Host → bootstrap → 设备证据。上游协议未合并前，下游 agent 不复制临时结构体到自己的模块。

### 11. Patch 与证据纪律

- 不能用 NOP、强制条件跳转、always-YES hook、全局 assert bypass、零 buffer stub 作为正式修复。
- 若为了定位临时绕过，必须标为 `DIAGNOSTIC`，默认关闭，并在同一问题记录中写出尚未恢复的 invariant。
- 原因结论必须标注 `RE-confirmed via ...` 或 `runtime-confirmed via ...`；未确认内容写 `THEORY` 并附验证方法。
- 稳定性必须有可见帧、递增计数、完成回调和内存曲线，不接受只给进程 `etime`。
- 性能改动必须保存改前/改后同负载数据，不能用主观“感觉更流畅”替代。

## 四、实现状态与证据

### 1. 已实现并在本地构建确认

- MacWSHost arm64 iOS 16 target 编译、链接、签名通过。
- macwsdisplayd、macwsinputd arm64 macOS 13 target 编译、链接、签名通过。
- libmachook/AppInputBridge arm64 + arm64e 编译、合并、签名通过。
- Stream/Input/Interop/Metrics 描述符校验测试通过。
- 完整窗口 aspect-fit、1.5×/2× 放大视口、中心钳制、触摸映射纯 C 测试通过。
- shell/plist/完整 package 验证命令列在后文；最终结果以当前变更的 QA 记录为准。

“本地构建确认”只代表类型、ABI 和链接可成立，不代表 iPad 上能够收到帧或达到性能目标。

### 2. RE-confirmed 的 macOS 13.4 私有接口事实

目标 SkyLight UUID：`96676A53-B1E0-3D7E-B98B-B73873CD1880`。

- `SLSHWCaptureStreamCreateWithWindow` 位于 `0x185210714`。
- 其入口保留 x0–x4，分别对应 window ID、32-bit frame-selection flag、properties、dispatch queue、handler；x0 在 preflight 传给 `CGSLocalWindowByID`。
- WindowServer 侧 `CGXHWCaptureStreamCreate` 把 x1 保存到 `WSCaptureStream+0x40`；`WSCaptureStreamStart` 读取该 byte，在 frame shape 与 content shape 路径之间选择。
- 当前实现传 `(windowID, false, properties, queue, handler)` 选择 content shape，并没有虚构 connection ID。

以上是二进制逆向事实。content shape 是否精确包含标题栏、阴影以及与 `NSWindow.frame` 的像素偏移，仍然是设备运行门槛，不由这段 RE 自动证明。

### 3. iPadOS 16.3.1 Scene 布局的 Source 与 RE 证据

**开源实现证据**

- Source-confirmed via TrollPad tag `1.3` / commit `bc31c3a7344576cfa7bb6a6db3136578e0f094ee`：`SBSwitcherChamoisLayoutAttributes` 的 `setGridWidths:` / `setGridHeights:` hook 用 20 point 步长重建两个数组，并保留系统原数组的最大值。
- TrollPad 1.3 的 Theos target 为 `iphone:clang:16.5:15.0`，tweak 注入 `com.apple.springboard`；README 把 Stage Manager 支持范围写为 iOS 16 及以上。[1.3 发布说明](https://github.com/khanhduytran0/TrollPad/releases/tag/1.3)明确列出 “resize window more freely”。
- 外部用户报告 [TrollPad issue #33](https://github.com/khanhduytran0/TrollPad/issues/33) 表明 iPad 上可以更自由地改变尺寸，但缩到最小时可能崩溃；该报告没有给出精确 OS build，只能作为风险提示，不能作为目标 16.3.1 的 runtime-confirmed 证据。

**目标二进制逆向证据**

证据文件：`~/Library/Developer/Xcode/iOS DeviceSupport/iPad13,6 16.3.1 (20D67)/Symbols/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard`；Mach-O `LC_BUILD_VERSION minos 16.3`，UUID `13B37E5E-5290-3E2E-91B9-4378BD2E8312`，SHA-256 `ecb1612c4116a01b4ccb363d24be7c4df0e54a24922478234a09224dd819092c`。

- RE-confirmed via SpringBoard `0x1c7bd5264` / `0x1c7bd5274`：`-[SBSwitcherChamoisLayoutAttributes setGridWidths:]` 与 `setGridHeights:` 调用 `_objc_setProperty_nonatomic_copy`，分别写入对象偏移 `0xb0` / `0xb8`。
- RE-confirmed via `-[SBSwitcherChamoisSettings layoutAttributesForContainerBounds:…]` `0x1c7bd2448`：生成的宽高数组分别在 `0x1c7bd2cb8` / `0x1c7bd2cc4` 通过上述 setter 写入 layout attributes。
- RE-confirmed via `-[SBSwitcherChamoisSettings _nearestGridSizeForSize:gridWidths:gridHeights:bounds:]` `0x1c7bd311c`：函数分别对两个数组执行 `count → objectAtIndex: → doubleValue`，用 `fabd` 计算候选值与请求宽/高的绝对差，并保留差值最小的候选。这证明数组内容参与真实 Stage Manager 尺寸量化，而不是只影响窗口装饰或截图比例。
- RE-confirmed 的能力是“任意提供一组合法候选值并由系统吸附到最近值”。TrollPad 实际提供 20 point 密集离散网格；每 1 point 连续档位、低于系统/应用安全下限以及最终 Scene geometry 提交仍未 runtime-confirmed。
- RE-confirmed via 目标 20D67 SpringBoard `-[SpringBoard _handleMakeFullscreenKeyShortcut:]` `0x1c7669964`：`windowSceneManager → activeDisplayWindowScene → switcherController` 后检查并执行 keyboard shortcut action `0x0b`。生产全屏桥复用这条完整系统路径，不再依赖只面向 Scene activation 的 `_requestFullscreen` flag。
- RE-confirmed via 目标 20D67 UIKitCore `-[UIScene _sceneIdentifier]` `0x189322ff0` 与 SpringBoard `+[SBDisplayItem applicationDisplayItemWithBundleIdentifier:sceneIdentifier:]` `0x1c773f33c`：前者返回的 FBS Scene ID 被后者用作 display item `uniqueIdentifier`，可以精确区分同一 Host bundle 的多个窗口。
- RE-confirmed via 目标 20D67 UIKitCore symbol/disassembly inventory：`-[UIWindowScene isFullScreen]` 位于 `0x189f44284`，`-[UISceneActivationRequestOptions requestingScene]` / `setRequestingScene:` 位于 `0x18a166564` / `0x18a16656c`。Host 用前者作为异步结果 witness，并仅用后者归属新 Scene activation；不再设置未证明有用的 layout 私有 flag。
- RE-confirmed via `-[SBItemResizeGestureSwitcherModifier _responseForSceneSizeUpdateToSize:center:sceneUpdatesOnly:]` `0x1c79cfaf4`：系统尺寸路径调用 `_SBDisplayItemAttributedSizeInfer`，通过 `attributesByModifyingAttributedSize:` / `attributesByModifyingSizingPolicy:` 构造不可变 layout attributes，再用 `appLayoutByModifyingLayoutAttributes:forItem:` 和 `appLayoutByBringingItemToFront:inAppLayout:` 得到新 app layout，最后创建 `SBMutableSwitcherTransitionRequest`。
- RE-confirmed via `-[SBMainSwitcherControllerCoordinator switcherContentController:performTransitionWithRequest:gestureInitiated:]` `0x1c79e67b8`：非手势请求被提交给 `SBMainWorkspace`。MacWS 初始尺寸桥按同一 ABI 和对象事务执行；不直接写 SpringBoard ivar、`UIWindow.frame` 或 CALayer transform。

因此当前把密集尺寸档位列为高可行性、RE-confirmed 工作项，同时保留设备运行门槛：记录原始数组、证明 hook 命中、证明 `UIWindowScene.bounds` 采用新增档位，并完成 safe area、输入坐标、键盘、拖放和四窗稳定性回归。TrollPad 的 150 point 下限不能提升为 MacWS 的已证实安全不变量。

### 4. 本地运行 probe 的边界

开发 Mac 为 macOS 26.3.1，不是目标 macOS 13.4 chroot。两种 private flag 的 create/start 都返回 `CGDisplayStreamStart == 0`，但三秒内没有 frame callback。

这个结果只确认本机接受当前参数形状；它不能证明 macOS 13.4 chroot 会出帧，不能证明 IOSurface 能跨到 iPad Host，也不能用于推断性能。

### 5. iPad 运行确认与剩余门槛

已确认（2026-07-31，`iPad13,6 / iPadOS 16.3.1`）：

- runtime-confirmed via `MacWSHost.log`：窗口 37 的新 Scene 第一帧为 `frame=1770x1156 source=IOSurface status=4 error=nil`。它由 `macwsdisplayd` 的 `stream-start id=10 mode=2 window=37` 对应，不经过 RFB 编解码或全屏 mmap 上传。
- Host 生产默认只接受 DisplayStream IOSurface。历史 `/tmp/macws_vnc_fb` 上传由 `MacWSLegacyFramebufferFallback` 显式偏好控制，默认关闭；单窗口模式即使打开该偏好也不会回退到全桌面截图。
- runtime-confirmed via `host-native/motion-60hz-direct-10s.log`：600 个 move 中 599 个成为真实 AppKit drag，59.88 Hz，延迟 p50 0.565 ms、p95 0.806 ms；down/up 顺序完整。该测试直接发送 `MacWSInputRecord-v4`，没有 VNC 客户端。
- runtime-confirmed via `host-native/semantic-matrix.json`：左键、拖动、右键、双轴滚动、普通/Shift/Caps/Control/Command 键与 Tab/Backspace/Return/Escape 的语义矩阵通过。
- runtime-confirmed via LLDB：Terminal 的右键路径进入 `rightMouseDown:` → `NSCarbonMenuImpl _popUpContextMenu` → `SLMPerformPopUpCarbonMenu` → `TrackMenuCommon` → `_NSHLTBMenuEventProc`，主线程在同步嵌套 tracker 中等待。因此后续 menu hover/click 不能依赖被阻塞的普通 main-CFRunLoop 输入 drain。
- runtime-confirmed via `macwsdisplayd.err` 和可见截图：Terminal 基础窗口 26 打开菜单时创建 `layer-start stream=17 base=26 layer=32 level=101 destination=(726,566 282x328)`；选择 Copy 后记录 `layer-remove base=26 layer=32`，菜单像素从 Host 画面消失，Terminal 保持存活。修复在 tracker 激活期间把普通 `NSEvent` 放入实际应用队列，仍由 AppKit/HIToolbox 做命中和动作，没有硬编码菜单项。
- runtime-confirmed via `MacWSHostd.log` / `MacWSHost.log`：再次打开 Terminal 命中 `launch-app reuse id=terminal pid=99577 ... identity=proc_pidpath`，随后 Host 记录 `launch-auto-window app=terminal pid=99577 window=15 group=15`；测试前后只有一个该可执行文件进程。
- runtime-confirmed via SpringBoard witness：dense-grid height 为 `original=4 expanded=36 minimum=603 maximum=922`，width 为 `original=8 expanded=109 minimum=327 maximum=1341`；Host 同期收到 `710x810`、`1004x670`、`1004x807`、`1052x671` 等 Scene geometry。该证据确认新增候选和多种真实 Scene bounds 已到运行系统，但用户手指拖过全部档位的最终手感仍待复测。
- runtime-confirmed via Terminal diagnostics：一条 420-point scroll change 命中精确窗口 54 并记录 `route=NSWindow.sendEvent`，截图显示内容实际滚动。120 个约 60 Hz scroll change 在 2.003 秒内发送；第 120 帧记录 capture→receipt 1.615 ms、receipt→submit 5.755 ms、submit→complete 2.633 ms，producer `outstanding=1 dropped=0`。这不是整段交互的 input-to-visible p95，不能据此宣称完整 60 fps 验收已通过。
- runtime-confirmed via `macwsdisplayd.err`（2026-08-02）：冷启动时 AppKit 给出 `runtime-confirmed AppKit display backing-scale=2.000 frame={{0, 0}, {1194, 834}}`。全屏 canvas 随后记录 `workspace-start id=3 display=2388x1668 scale=2.000`，基础帧与桌面层目的坐标均为 2388×1668，修复了旧 1194×834 canvas 与 2× layer/input 坐标混用造成的放大裁剪和点击偏移。
- runtime-confirmed via `macwsdisplayd.err` + 双客户端集成探针（2026-08-03）：完整桌面捕获图是唯一物理资源。新的前台全屏 Scene 直接接管仍在运行的 stream/layer 对象和各层最后一张 IOSurface，不 stop/recreate SkyLight 捕获流。正式包的 witness 为 `workspace-handoff stream=1 layers=11 ... transport=live-graph-transfer`，WindowServer PID `78356` 和 displayd PID `79399` 交接前后不变；对照失败实现曾得到 PID `75537 → 78356` 和 `layer-start failed ... error=-308`。Host 在新代际首帧前提交黑色 Metal clear，旧单窗 drawable 不会被系统全屏动画放大成伪桌面。完整证据见 [`fullscreen-aqua-workspace-20260802.md`](fullscreen-aqua-workspace-20260802.md)。
- runtime-confirmed via `MacWSHost.log`（2026-08-02）：从 Terminal window 21/group 16 进入桌面后，第二次同一 action 记录 `scene-reused mode=window restored-from-workspace window=21 owner=35681 group=16 scene-size=1194.0x807.0`；持久化字典从 `mode=1, return_window_id=21` 回到 `mode=2, window_id=21`。Host 进程重建与 DisplayStream 服务重连后仍能恢复该精确窗口身份。
- runtime-confirmed via设备端 Host UI 截图（`/var/mobile/Library/Logs/MacWSHost-ui.png`）：全屏画面没有 Host 语义菜单栏，保留完整 macOS 原生菜单栏和右上角独立材质按钮；展开控制中心为不透出桌面颜色的浅色实底，标签、分段控件与按钮对比度一致。
- 当前画面性能尚未达标：关闭 `OSXvnc-server` 和全屏 mmap producer 后，同一动态窗口的接受序号 120→240 用时 3.210 秒（37.4 fps），240→360 用时 3.106 秒（38.6 fps）；producer 同期记录 `outstanding=2/3` 和持续 drop。带 VNC 会话的同负载为约 38–40 fps，因此 RFB/mmap 已被 A/B 排除为主因。这里只把剩余瓶颈归到 DisplayStream/lease/presentation 边界，具体根因仍需新的运行或 RE 证据。

仍待确认或修复：

- 全屏 Retina canvas、完整 on-screen SkyLight z-order、原生菜单栏和动态 Terminal 首帧已经 runtime-confirmed；Dock、多个 Space、持续动态负载和 IOSurface 内存上界仍待独立压力验证。生产 Host 不再用 mmap 静默掩盖该路径。
- v6 自然装载后验证精确 FBS Scene 的 action 11 是否产生真实 `isFullScreen=YES`、Scene bounds 变化、状态栏/Home Indicator 隐藏以及原 Scene session 不变；不能用内容铺满当前小 Scene 代替。
- v6 自然装载后从真实小型 macOS utility panel 创建新 Scene，记录请求尺寸、`resize-performed ... route=SBMainWorkspace`、最终 Scene bounds 和 AppKit frame；静态 RE 与构建成功不能替代这条运行证据。
- 四个前台 Scene 在台前调度下持续稳定。
- 用手指连续拖过密集档位，逐档确认 `UIWindowScene.bounds`、drawable、AppKit frame 和输入坐标一致；已有运行 witness 只证明新增候选和多种 Scene geometry 已出现，不能替代该交互回归。
- 验证密集档位的系统级影响和 Scene 隔离；当前 setter hook 仍改变全局候选数组，非 MacWS 应用不得因此出现布局、safe area、键盘、拖放或触摸命中回归。
- AppKit 动态最小尺寸、固定尺寸窗口和 density resize 的实际行为。
- 缩放后的四角点击、拖动、滚动、软键盘和妙控键盘输入一致性。
- 全屏屏幕三指候选、桌面命令 capability/result，以及外接妙控板三指是否被 iPadOS 截获的输入日志。
- pboard 通知、rootfs 权限、安全作用域 URL、iPad 拖入/拖出。
- 全屏工作区的焦点切换与复杂菜单兼容入口。
- Scene 菜单展开面板的 macOS 原生外观、hover/键盘导航、复杂 view/submenu 和四 Scene 跨 PID 隔离压力；基础快照、generation 和原动作桥不再列为未实现。

## 五、测试与验收方案

### 1. 本地静态与构建测试

```bash
cc -std=c11 -Wall -Wextra -Werror -Iinclude \
  misc/macws_protocol_test.c -lm -o /tmp/macws_protocol_test
/tmp/macws_protocol_test

gmake -C MacWSHost all GO_EASY_ON_ME=1
gmake -C macwsdisplayd all GO_EASY_ON_ME=1
gmake -C macwsinputd all GO_EASY_ON_ME=1
gmake -C macwsinteropd all GO_EASY_ON_ME=1
gmake -C libmachook all GO_EASY_ON_ME=1

plutil -lint MacWSHost/Resources/Info.plist \
  layout/usr/macOS/LaunchDaemons/com.macwsguide.display.plist \
  layout/usr/macOS/LaunchDaemons/com.macwsguide.interop.plist
bash -n layout/usr/macOS/bin/macos_gui.sh misc/cleanup_all.sh
git diff --check
```

### 2. 小窗口与密度矩阵

至少选择 Terminal、Finder/系统应用、Electron、固定尺寸面板各一个：

1. 记录应用发布的真实 min frame。
2. 在像素匹配 Retina 下，把 Scene 调到门槛 `+1 point`：不得遮罩，应用布局完整，并记录 source/drawable 像素是否 1:1。
3. 调到门槛 `-1 point`：必须整窗遮罩，所有 macOS 输入停止。
4. 切换更多空间 +18%：若达到新门槛，遮罩撤下，AppKit 发生一次合并后的重排。
5. 固定尺寸窗口：不发送 resize；Scene 过小时遮罩。
6. 应用运行中改变 `contentMinSize`：500–1000 ms 内目录和遮罩更新。
7. 快速拖过所有台前调度档位：不能形成 resize 循环、日志风暴或持续边距；交接期旧帧可以短暂留边，但任何一帧都不能拉伸变形。
8. 在原始档位之间选择一个新增密集档位：窗口装饰、`UIWindowScene.bounds`、Host drawable、macOS 目标 frame 和输入坐标必须最终一致；不能只是拉伸旧画面。
9. 新增档位小于当前应用门槛：只出现整窗遮罩，菜单和 Host 控制入口仍可用；放大到门槛后只发生一次合并后的最终重排。
10. 同时打开 MacWS 与普通 iPad 应用反复 resize：若实现尚为全局实验开关，必须单列记录普通应用的 geometry/safe-area 回归；实现 Scene 隔离后则验证普通应用仍只使用系统原始策略。

### 3. 缩放与输入矩阵

- 在 1×、1.5×、2×分别点击可见区域四角、中心和窗口标题栏控件；目标偏差不得随 zoom 增大。
- 单指在 450 ms 与 6 pt 阈值的两侧分别验证：短按只点击一次，先越过移动阈值形成滚动，先越过时间阈值后移动才形成连续左键拖动，长按不移动释放只右键一次。
- 第二指在候选阶段加入时不得产生左/右键；在左键拖动阶段加入时，macOS 必须收到 cancel，不能留下卡住的 mouse-down。
- 1× 双指滑动必须滚动 macOS 内容；进入放大后默认移动视口，规范化 visible rect 始终在 `[0,1]` 内。
- 放大 HUD 切到“操作内容”后，双指滑动必须滚动内容而不移动视口；切回“移动视图”后行为相反。
- 双指双击位置应成为放大锚点；再次双击和控制面板按钮都恢复 1×/居中。设置切换 1.5×/2× 后，下一次进入放大使用唯一的新倍率。
- Photos/Safari 原生 magnify 单列为待验证项；在取得 macOS 13.4 gesture event 的 RE 与运行证据前不得判为通过。
- 妙控键盘 pointer 在缩放视口边缘触发跟随后，hover 与 click 仍落在同一控件。

### 4. Scene 顶部菜单栏矩阵

- 紧凑态文字在所有台前调度档位清晰可读，固定栏高不因菜单内容变化而抖动，也不覆盖 macOS 标题栏。
- 点击每个标题的字形、两侧空白和相邻标题中线两边，命中必须确定且可重复；第一次点击只能展开分类，不能执行任何菜单项。
- 展开态尺寸达到触摸目标，第二次点击准确执行；展开/收起不发送 configure-window、不改变纹理视口和输入映射。
- 展开时在所有顶层标题间连续滑动，内容、选中态和 generation 保持同一个精确 owner PID/window，不能串到其他前台 Scene。
- disabled、勾选、混合状态、快捷键、分隔线和三级子菜单与目标 AppKit 菜单一致；过期 generation 和已关闭窗口必须拒绝动作并刷新。
- Terminal、Finder/系统应用和 Electron 各验证一次动态 responder 菜单；切换目标窗口后 enabled/state 在下一次展开时更新。
- 极窄窗口只显示受控的顶层子集和“更多…”，长菜单内部滚动；子菜单、中文长标题和超大字体不能越出 safe area。
- 内容过小遮罩出现时菜单仍能执行关闭/偏好设置；Scene 失焦、后台、旋转和 resize 必须自动收起。
- 妙控键盘下验证点击、hover、方向键、Enter、Esc 和快捷键；不能触发触屏稀疏布局。
- 四个 Scene 同时前台反复开关菜单 30 分钟：无跨 PID 动作、无快照泄漏、无主线程卡死；点击到本地展开动画应在一帧内开始，子树响应 p95 目标不高于 100 ms。
- `NSMenuItem.view`、Services 等未支持项目必须明确导向全屏菜单栏，不能静默丢失或错误执行。

### 5. 全屏三指桌面手势矩阵

- 只在全屏 `windowID == 0` 生效；相同三指动作在单窗 Scene、菜单、软键盘、控制面板和系统边缘区域不得发送 desktop command。
- 屏幕虚拟触控板分别验证上、下、左、右、短距离、低速度、斜向和反向手势；每个有效 gesture sequence 只执行一次，无效手势不产生副作用。
- 第三指加入单指候选、左键拖动和双指滚动的各个阶段，验证候选取消、mouse cancel 和滚动停止，不得留下卡住的按钮或额外 scroll。
- Mission Control、App Exposé、previous/next Space、Show Desktop 分别保存 command、result 和可见桌面变化；没有可见变化的 success 回执判为失败。
- 后端断线、命令超时、不支持 capability、全屏 Scene 中途失焦时，HUD 必须显示不可用/取消，不能静默降级或重复执行。
- 外接 Magic Trackpad 在目标 iPadOS 16 上记录三指上/下/左/右是否到达 UIKit；未到达视为系统所有的预期结果，不以私有 hook 绕过。
- Control + 双指替代入口验证四个方向、修饰键抬起和普通双指滚动；没有 Control 时不得触发桌面命令。
- VoiceOver/AssistiveTouch 开启时重新验证或自动禁用冲突映射，不能抢占辅助功能手势。
- 全屏 Metal View、单窗 Metal View、软键盘输入代理、设置文本框和文件选择器分别读取 `editingInteractionConfiguration`：只有“全屏 + 键盘关闭 + 桌面手势可用”的 Metal responder 返回 `None`。
- 在全屏 Metal View 三指左右滑时，Host desktop command 只能触发一次，UIKit `undoManager` 的 undo/redo 计数不得变化；退出全屏或打开软键盘后，普通 UIKit 编辑控件的三指撤销/重做必须恢复。
- 三指 pinch 在全屏下不得被方向 recognizer 误判；普通 UIKit 编辑 responder 的 copy/paste 行为保持系统默认。

### 6. IOSurface 与四窗稳定性

1. 一个 60 fps 动态窗口连续 10 分钟；日志中不得出现 mmap upload，outstanding lease 永远不超过 3。
2. 四个不同 macOS 窗口同时前台，持续 resize、重叠、旋转、后台/前台 30 分钟。
3. 内存经过预热后应进入有界波动；关闭 Scene 后对应 IOSurface lease 归零。
4. 故意让 Host 慢消费：producer 只增加 drop，不阻塞 WindowServer、不无限分配。
5. 停止 macwsdisplayd：Host 明确显示回退/断开状态；VNC 保留为诊断入口。

### 7. 性能产品门槛

以下是验收目标，不是当前实测结论：

- 活跃拖动/滚动目标 60 fps；1% low 不低于 45 fps。
- producer callback → Host Metal submit 的 p95 不高于 8 ms。
- producer callback → Metal completion 的 p95 不高于 25 ms。
- 用户输入 → 可见画面变化的 p95 不高于 50 ms。
- 正常交互帧的 backpressure drop 低于 1%，不得连续 500 ms 满三帧。
- 四窗 30 分钟无 crash、jetsam、surface 泄漏、输入卡住或持续 resize 抖动。
- 温控进入 serious/critical 时允许有记录的降帧策略，但不能无提示卡死；降帧后输入仍优先。

所有时延都从共享 Mach clock 的 capture、XPC receipt、Metal submit/completion 和 input sequence 计算。无法关联到同一 sequence 的样本不得混入结果。

### 8. 互操作验收

- 双向文本：空串、中文、emoji、多行、8 MiB 边界。
- PNG/JPEG：透明通道、大图、重复内容、方向 metadata。
- 文件：1 byte、大文件、多文件、同名、Unicode 名、只读源、服务重启。
- iPad 拖入窗口和拖出到 Files/其他应用；用户取消时清理临时文件。
- 同一剪贴板内容往返 100 次不得 generation 回环。
- canonical path 越界、`..`、符号链接逃逸和超限 payload 必须拒绝并记录原因。

## 六、里程碑与后续工作

### M0：本地可构建基线

- 协议、Host、display、input、interop、AppInputBridge 全部构建。
- 纯函数与 malformed descriptor 测试通过。
- 中文方案、模块 owner 和证据标签齐全。

### M1：单窗首帧

- macOS 13.4 private window stream 出帧。
- IOSurface Mach right 在 iPad Host 导入为 AGX Metal texture。
- 四角几何和标题栏边界有截图、日志和像素测量证据。

### M2：触屏可用

- 最小尺寸遮罩、原生 Retina 密度、二段式放大、单指滚动、单指点击、长按拖动/右键在三类应用通过。
- Photos/Safari 的原生 magnify 在真实事件注入路径确认后作为独立增量验收，不阻塞 Host 视口放大能力。
- 修复只能发生在产生错误状态的上游，不接受输入常量偏移补丁掩盖几何问题。

### M3：妙控键盘与四窗

- 更多空间密度、圆形相对指针、键盘、双指滚动、快捷键通过。
- 全屏屏幕三指桌面命令与外接妙控板修饰键替代入口通过；外接原生三指能力按设备证据启用。
- iPadOS 16 密集台前调度档位使用真实 Scene geometry，通过新增档位几何一致性、普通应用隔离和安全恢复测试。
- 四个 Scene 达到稳定性和性能门槛。

### M4：互操作与菜单

- 文本、图片、文件、拖放通过。
- 保留全屏真实菜单栏兼容入口；实现带 generation 的 Scene 顶部语义菜单桥。
- 触屏“紧凑可读 → 首次点击展开 → 第二次点击执行”和妙控键盘紧凑逻辑分别通过菜单栏矩阵。

### M5：发布候选

- 30 分钟压力、温控、后台恢复、服务崩溃恢复通过。
- 直传/回退状态可见；所有未完成私有接口风险写入发布说明。
- 证据目录能从结论追溯到原始日志、截图、二进制 UUID 或 disassembly。

## 七、明确非目标

- 不支持 macOS 13.4 之外版本的私有 SkyLight offset 兼容。
- 不依赖 RFB 压缩来呈现 iPad UI；RFB/VNC 只作诊断和兼容。
- 不通过全局 DPI 频繁切换实现逐窗口密度。
- 不把全桌面截图裁成单窗来伪造菜单；同 owner、与基础窗口相交的真实 SkyLight 瞬态窗口必须作为独立 IOSurface layer 传输并由 Host Metal 合成。
- 不突破 iPadOS 同时四个前台窗口的产品上限。
- 不用跳过 assert、伪造成功返回或零对象 stub 换取表面“稳定”。
