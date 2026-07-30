# MacWS Host 多窗口、显示与触屏交互总方案

> 目标平台：iPadOS 16、台前调度、macOS 13.4 chroot。
> 设计优先级：触屏体验 > 妙控键盘体验 > 兼容性回退。
> 文档状态：2026-07-30；区分“已实现并本地构建确认”和“等待 iPad 运行确认”。

## 一、方案总览

### 1. 产品目标

把 macOS 应用的每个顶层窗口映射为一个独立的 iPadOS `UIWindowScene`，让用户用台前调度同时组织最多四个 macOS 窗口。画面采用 DisplayStream → IOSurface → Metal 直传，交互默认针对手指设计，同时完整保留妙控键盘的指针和键盘效率。

这个产品不是远程桌面皮肤，也不是把整个 macOS 桌面缩小后塞进 iPad 窗口；iPadOS Scene 是一等窗口，macOS `NSWindow` 是它背后的应用窗口。

### 2. 核心工作与原理

| 核心工作 | 非常简要的工作原理 | 当前状态 |
|---|---|---|
| DisplayStream 直传 | SkyLight/CGDisplayStream 产生 IOSurface，XPC 只传 Mach right 和描述符，Host 直接创建 Metal texture | 已实现；iPad 待验证 |
| macOS 窗口 → iPadOS Scene | 每个 Scene 保存一个真实 `CGWindowID` 和 owner PID，独立订阅、恢复和释放 | 已实现；四窗待验证 |
| 无黑边显示 | 正常状态始终 edge-to-edge；宽高比短暂不一致时裁剪源纹理，不使用 aspect-fit | 已实现并有纯 C 单测 |
| 小窗口保护 | AppKit 发布窗口真实最小尺寸；Scene 小于要求时整窗遮罩并停止向该窗口注入输入 | 已实现；iPad 待验证 |
| 触屏/键鼠双密度 | 改变 Scene 对应的 macOS 逻辑窗口尺寸，让触屏模式控件更大、键鼠模式信息更多 | 已实现；iPad 待验证 |
| 缩放与精确操控 | 双指双击在 1× 与用户配置的 1.5×/2× 间切换；放大后默认移动视口，输入坐标同步映射到裁剪后的源纹理 | 已实现并有数学单测；原生 magnify 待验证 |
| 直接触控与触控板 | 单指可直接点控；也可把玻璃当相对触控板；妙控键盘指针始终保持绝对坐标 | 已实现；设备兼容性待验证 |
| Scene 顶部菜单栏 | 从目标 AppKit 进程同步 `NSMainMenu` 语义；触屏采用“紧凑可读 → 首次点击展开 → 第二次点击执行”，键鼠保持紧凑桌面逻辑 | 全屏入口已实现；Scene 语义菜单待实现 |
| 剪贴板、图片与文件 | iOS 与 macOS 之间通过有界 XPC 协议同步文本/图片并暂存文件，使用 generation 防回环 | 已实现；权限与拖放待验证 |
| 性能与稳定性 | 每客户端最多三帧在途，Metal 完成后才释放 surface；慢消费者丢新帧而不阻塞 WindowServer | 已实现；性能目标待实测 |

### 3. 端到端结构

```text
macOS 应用进程
  ├─ NSWindow / NSApplication
  ├─ AppInputBridge：真实最小尺寸、原生重排、应用内输入
  ├─ 菜单桥：NSMainMenu 语义快照、generation 校验、原动作执行（规划）
  └─ metrics.<pid>.bin（低频控制面）
             │
             ▼
macwsdisplayd（macOS 13.4 chroot）
  ├─ 窗口目录：CGWindowID + owner PID + AppKit 最小尺寸
  ├─ 全屏：CGDisplayStream
  └─ 单窗：SLSHWCaptureStreamCreateWithWindow
             │ IOSurface Mach right + 帧描述符；无 RFB 编解码
             ▼
MacWSHost（iPadOS）
  ├─ 一个 macOS 窗口对应一个 UIWindowScene
  ├─ IOSurface → MTLTexture → MTKView
  ├─ 无黑边视口、缩放、遮罩、密度选择
  └─ Scene 顶部语义菜单 / 触摸 / 妙控键盘 / 拖放 / 剪贴板
             │ 52-byte 有版本输入记录
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
- 选择后创建一个新 `UIWindowScene`，Scene 的 `NSUserActivity` 持久化 `CGWindowID`、owner PID、最小尺寸、是否可缩放以及显示密度。
- 全屏工作区使用 `windowID == 0`，用于桌面、全局菜单栏和尚未适配成独立 Scene 的窗口。
- Scene 进入后台时取消订阅；Metal fence 完成后释放所有 IOSurface lease。恢复前不把旧截图当成可交互画面。
- 第一阶段必须避免同一 `CGWindowID` 被两个前台 Scene 同时控制。后续应加入跨 Scene 的窗口所有权登记；重复打开时优先激活已有 Scene。

### 2. 小尺寸窗口：整窗遮罩，不使用 aspect-fit

判定公式：

```text
触屏模式所需 iPad 宽高 = macOS 最小 frame 宽高 × 1.35
键鼠模式所需 iPad 宽高 = macOS 最小 frame 宽高 × 1.00
```

只要 Scene 的可用宽度或高度低于当前模式要求：

- 用接近不透明的系统背景覆盖整个渲染区域；不显示黑边和被挤坏的 macOS UI。
- 文案同时显示应用要求、当前模式要求，并引导“放大 iPadOS 窗口”或“切换键鼠高密度”。
- 禁止该 Scene 的触摸、指针和键盘注入，防止用户在不可见位置误操作。
- 保留 Host 控制面板入口，用户仍可切换密度、选择其他窗口或进入全屏工作区。
- 当窗口重新达到要求时自动撤去遮罩，并以 180 ms 防抖向 AppKit 请求重排。

如果最小尺寸尚未从应用进程发布，协议中的值为 0，含义是“未知”，不是“没有最小尺寸”。Host 不猜一个全局常量；AppKit 仍会钳制实际 resize，下一次窗口目录刷新后再做遮罩判定。

### 3. 正常显示：无黑边铺满

- Host 的目标是让 macOS 窗口按 `SceneSize / densityScale` 重排，使源窗口与 Scene 尽量同宽高比。
- 窗口重排期间、旋转期间或 DisplayStream 尺寸更新尚未到达时，Metal 使用 aspect-fill：目的区域永远铺满，差异由规范化源纹理裁剪承担。
- 不允许 aspect-fit，也不生成上下或左右黑边。
- aspect-fill 是短暂过渡和缩放基础，不是长期替代原生重排。持续裁剪过多必须通过日志和设备测试暴露。

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

- **触屏舒适 135%**：一个 macOS 逻辑点占约 1.35 个 iPad 点。对同一个 Scene 请求更小的 macOS 逻辑 frame，应用通过原生 Auto Layout/AppKit 布局把文字和控件显示得更大。
- **键鼠高密度 100%**：一个 macOS 逻辑点占 1 个 iPad 点，容纳更多内容，适合妙控键盘和精确指针。
- DisplayStream 的真实 `backingScale` 仍用于 HiDPI 像素传输；密度模式不伪造 IOSurface 尺寸，也不对最终画面做低质量二次位图放大。
- 切换模式会恢复视口缩放、重新计算小窗口门槛，然后防抖请求 AppKit 重排。

因此，这里实现的是“每个 Scene 的有效信息密度”，不是修改 macOS 全局 DPI。将来若验证出 macOS 13.4 可安全逐窗口设置 backing scale，必须先证明窗口纹理、命中测试、菜单和跨屏拖动四者一致，才能替换当前方案。

### 6. 触摸与妙控键盘

**默认直接触控**

- 单指落下先进入候选状态，不立即发送 mouse-down；位置直接对应当前可见纹理中的 macOS 像素。
- 450 ms 内抬起且移动不足 6 pt：发送一个原子左键单击。
- 450 ms 前移动达到 6 pt：补发起点的左键 down，随后发送 move，抬起发送 up，形成 macOS 左键按住拖动。
- 保持 450 ms 且移动不足 6 pt：发送一个原子右键单击并触发轻触觉反馈；之后移动只更新菜单 hover，不维持一个跨数据报的右键按下状态。
- 第二根手指加入会取消候选；若左键拖动已经开始，Host 发送 cancel。这样双指滚动/放大不会留下卡住的按钮状态。
- 适合经过触屏密度放大的按钮、列表、标签页、拖动目标和右键菜单。450 ms 与 6 pt 是产品阈值，设备测试后可以统一调整，不能在各手势回调里复制不同常量。

**精确触控板**

- 单指相对移动鼠标；轻点为原子左键点击；长按后移动为拖动。
- 双指轻点为原子右键；双指移动发送横向和纵向 pixel scroll。
- 右键 down/up 在一个数据报内表达，避免拥塞时 up 越过 down。

**妙控键盘**

- 间接指针/hover 始终走绝对坐标，不因当前手指模式而改成相对移动。
- USB HID usage 映射为 macOS keycode，同时保留字符、修饰键、方向键、功能键和组合快捷键。
- 软键盘与硬键盘共享同一个目标窗口和 owner PID；Scene 遮罩或流未就绪时都不能注入。
- 硬件键盘出现不应强制切换密度，以免用户正在触控时布局跳动；控制面板显式选择并持久化模式。后续可提供一次性建议，而不是自动改动。

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

全屏工作区继续保留真实 macOS 全局菜单栏，作为语义桥未就绪、复杂菜单和调试时的兼容入口。Scene 语义菜单目前尚未实现，也没有设备运行证据；上述尺寸和动画时间是产品目标，必须在 iPad 上调优后才能标记稳定。

### 8. 剪贴板、图片、文件与拖放

- 文本、PNG、JPEG 通过 XPC inline 传输，单项最多 8 MiB；描述符含 generation、origin 和 SHA-256 截断摘要。
- iPad → macOS 的文件先复制到 `/Users/Shared/MacWS Imports/<UUID>/`，然后作为原生 file URL 写入 NSPasteboard。
- macOS → iPad 的 file URL 经 `/var/mnt/rootfs` 映射，供粘贴、拖出和 share sheet 使用。
- 每次读取 iPadOS general pasteboard 必须由用户动作触发，避免无意触发系统粘贴隐私提示。
- 同一内容由 origin/generation 去重，服务重启后也不得在两端无限回弹。
- 安全作用域 URL 必须在复制完成后成对结束访问；路径需 canonicalize 并限制在允许的 rootfs/暂存目录内。

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

Host 在 Scene 布局稳定 180 ms 后发送 `MacWSInputKindConfigureWindow`：

```text
sceneID  = 精确 CGWindowID 编码
targetPID = 窗口 owner PID
x/y      = Scene 宽高 / densityScale，单位为 macOS logical point
pressure = densityScale
```

`macwsinputd` 只把这一控制记录路由给精确 PID，不构造 CGEvent。`AppInputBridge` 再次核对 window number，在应用主线程读取实时约束，将请求钳制到真实最小尺寸，然后用原生 `setFrame:display:animate:` 重排，并保留窗口顶边位置。

这是一条 AppKit 正常 resize 路径，不是 hook 验证函数、强制分支或跳过约束。任何应用仍可拒绝或重新调整请求；Host 必须以随后发布的窗口目录为准。

### 4. 无黑边视口与坐标公式

纯函数位于 `include/macws_viewport_math.h`，输入源纹理宽高、Scene 宽高、zoom 和 center，输出规范化 `visibleSource`。

基础 aspect-fill：

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

- `MacWSInputRecord` 保持 v3、固定 52 bytes。
- window Scene 使用 `sceneID` 的 bit 31 作为标记，高 32 位保存完整 `CGWindowID`，低 31 位保留修饰键。
- configure-window 沿用固定记录的新 kind 15，没有改变旧接收端的结构长度。
- 坐标始终是当前 producer frame 的物理像素，不是 iPad point 或全桌面坐标。
- AppInputBridge 每次事件都根据目标窗口当前 AppKit frame 做转换，不能缓存一个跨 resize 的旧 origin。
- 控制记录、键盘、滚动和指针都先验证 magic/version/finite/范围/owner PID；失败需有可归因日志。

### 6. 菜单快照与动作协议（规划）

菜单是低频、可变长控制面，不能塞进 52-byte 输入热路径，也不能为方便而复制未定稿结构体到 Host 和 AppInputBridge。建议单独定义版本化协议：

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

### 7. 协议边界

| 协议 | 版本与固定结构 | 重要上限 |
|---|---|---|
| Stream | window descriptor 64 B；frame descriptor 72 B | 16384 px；256 窗口；64 damage rect |
| Metrics | header 24 B；entry 16 B | 256 entry；原子 sidecar |
| Input | v3 record 52 B | 精确 PID/window；所有 float finite |
| Interop | item descriptor 56 B | 8 MiB inline；32 items；path 4096 B |
| Menu（规划） | 独立 snapshot + action 版本；结构待实现时确定 | 有界树深/node/字符串/payload；opaque item ID + generation |

协议变更必须：提升相应 version、保留旧端可诊断失败、更新 `_Static_assert`、增加 malformed-length/overflow 单测。不能只修改发送端和接收端之一。

### 8. 场景恢复与失效处理

- `NSUserActivity` 保存 mode、window ID、PID、最小尺寸、resizable、density。
- 恢复后立即重新请求窗口目录；目录中的实时 PID/约束覆盖持久化快照。
- 目标窗口关闭、PID 改变或 AppInput socket 消失时，Scene 显示“目标不可用”，停止输入并允许重新选择。
- surface 序号必须单调；旧 stream/window 的迟到帧释放但不呈现。
- 前后台切换、旋转和台前调度档位变化都必须使未执行的 resize 防抖任务失效。
- Scene 失焦、恢复、目标 PID/window 改变或尺寸变化时收起触屏菜单；持久化层不保存展开菜单、item ID 或旧 generation。

### 9. 文件与模块所有权

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
| Bootstrap owner | `layout/usr/macOS/`、根 Makefile | launchd 顺序、清理、签名、打包 |
| Evidence owner | `misc/`、`docs/evidence/` | probe、基准、日志索引、结果判定 |

建议集成顺序：协议与纯函数 → producer/AppKit → input/interop → Host → bootstrap → 设备证据。上游协议未合并前，下游 agent 不复制临时结构体到自己的模块。

### 10. Patch 与证据纪律

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
- 无黑边 aspect-fill、1×/1.5×/2× 视口、中心钳制、触摸映射纯 C 测试通过。
- shell/plist/完整 package 验证命令列在后文；最终结果以当前变更的 QA 记录为准。

“本地构建确认”只代表类型、ABI 和链接可成立，不代表 iPad 上能够收到帧或达到性能目标。

### 2. RE-confirmed 的 macOS 13.4 私有接口事实

目标 SkyLight UUID：`96676A53-B1E0-3D7E-B98B-B73873CD1880`。

- `SLSHWCaptureStreamCreateWithWindow` 位于 `0x185210714`。
- 其入口保留 x0–x4，分别对应 window ID、32-bit frame-selection flag、properties、dispatch queue、handler；x0 在 preflight 传给 `CGSLocalWindowByID`。
- WindowServer 侧 `CGXHWCaptureStreamCreate` 把 x1 保存到 `WSCaptureStream+0x40`；`WSCaptureStreamStart` 读取该 byte，在 frame shape 与 content shape 路径之间选择。
- 当前实现传 `(windowID, false, properties, queue, handler)` 选择 content shape，并没有虚构 connection ID。

以上是二进制逆向事实。content shape 是否精确包含标题栏、阴影以及与 `NSWindow.frame` 的像素偏移，仍然是设备运行门槛，不由这段 RE 自动证明。

### 3. 本地运行 probe 的边界

开发 Mac 为 macOS 26.3.1，不是目标 macOS 13.4 chroot。两种 private flag 的 create/start 都返回 `CGDisplayStreamStart == 0`，但三秒内没有 frame callback。

这个结果只确认本机接受当前参数形状；它不能证明 macOS 13.4 chroot 会出帧，不能证明 IOSurface 能跨到 iPad Host，也不能用于推断性能。

### 4. 等待 iPad 的运行确认

- macOS 13.4 单窗 stream 在目标 bootstrap/session 下开始并持续回调。
- IOSurface Mach right 从 chroot 进入 iPadOS Host，且在原生 AGX device 上成功创建纹理。
- 四个前台 Scene 在台前调度下持续稳定。
- AppKit 动态最小尺寸、固定尺寸窗口和 density resize 的实际行为。
- 缩放后的四角点击、拖动、滚动、软键盘和妙控键盘输入一致性。
- pboard 通知、rootfs 权限、安全作用域 URL、iPad 拖入/拖出。
- 菜单栏 content-shape 和全屏工作区的焦点切换。
- Scene 顶部紧凑菜单、触摸展开、精确 NSWindow 激活、generation 失效和原动作执行。

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
2. 在触屏 135% 下，把 Scene 调到门槛 `+1 point`：不得遮罩，应用布局完整。
3. 调到门槛 `-1 point`：必须整窗遮罩，所有 macOS 输入停止。
4. 切换键鼠 100%：若达到新门槛，遮罩撤下，AppKit 发生一次防抖重排。
5. 固定尺寸窗口：不发送 resize；Scene 过小时遮罩。
6. 应用运行中改变 `contentMinSize`：500–1000 ms 内目录和遮罩更新。
7. 快速拖过所有台前调度档位：不能形成 resize 循环、日志风暴或持续裁剪。

### 3. 缩放与输入矩阵

- 在 1×、1.5×、2×分别点击可见区域四角、中心和窗口标题栏控件；目标偏差不得随 zoom 增大。
- 单指在 450 ms 与 6 pt 阈值的两侧分别验证：短按只点击一次，越过移动阈值形成连续左键拖动，越过时间阈值只右键一次。
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

### 5. IOSurface 与四窗稳定性

1. 一个 60 fps 动态窗口连续 10 分钟；日志中不得出现 mmap upload，outstanding lease 永远不超过 3。
2. 四个不同 macOS 窗口同时前台，持续 resize、重叠、旋转、后台/前台 30 分钟。
3. 内存经过预热后应进入有界波动；关闭 Scene 后对应 IOSurface lease 归零。
4. 故意让 Host 慢消费：producer 只增加 drop，不阻塞 WindowServer、不无限分配。
5. 停止 macwsdisplayd：Host 明确显示回退/断开状态；VNC 保留为诊断入口。

### 6. 性能产品门槛

以下是验收目标，不是当前实测结论：

- 活跃拖动/滚动目标 60 fps；1% low 不低于 45 fps。
- producer callback → Host Metal submit 的 p95 不高于 8 ms。
- producer callback → Metal completion 的 p95 不高于 25 ms。
- 用户输入 → 可见画面变化的 p95 不高于 50 ms。
- 正常交互帧的 backpressure drop 低于 1%，不得连续 500 ms 满三帧。
- 四窗 30 分钟无 crash、jetsam、surface 泄漏、输入卡住或持续 resize 抖动。
- 温控进入 serious/critical 时允许有记录的降帧策略，但不能无提示卡死；降帧后输入仍优先。

所有时延都从共享 Mach clock 的 capture、XPC receipt、Metal submit/completion 和 input sequence 计算。无法关联到同一 sequence 的样本不得混入结果。

### 7. 互操作验收

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

- 最小尺寸遮罩、触屏密度、二段式放大、双指路由和单指点击/拖动/长按右键在三类应用通过。
- Photos/Safari 的原生 magnify 在真实事件注入路径确认后作为独立增量验收，不阻塞 Host 视口放大能力。
- 修复只能发生在产生错误状态的上游，不接受输入常量偏移补丁掩盖几何问题。

### M3：妙控键盘与四窗

- 键鼠高密度、指针、键盘、滚动、快捷键通过。
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
- 不为超出单窗 capture 范围的右键菜单做视口追踪。
- 不突破 iPadOS 同时四个前台窗口的产品上限。
- 不用跳过 assert、伪造成功返回或零对象 stub 换取表面“稳定”。
