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
| 台前调度密集尺寸档位 | iPadOS 16 的 SpringBoard `Chamois` 布局对象保存可选宽高数组；参考 TrollPad 增加候选档位，最终仍走系统 Scene geometry 事务 | iPadOS 16.3.1 二进制 RE-confirmed；运行待验证 |
| 无黑边显示 | 正常状态始终 edge-to-edge；宽高比短暂不一致时裁剪源纹理，不使用 aspect-fit | 已实现并有纯 C 单测 |
| 小窗口保护 | AppKit 发布窗口真实最小尺寸；Scene 小于要求时整窗遮罩并停止向该窗口注入输入 | 已实现；iPad 待验证 |
| 触屏/键鼠双密度 | 改变 Scene 对应的 macOS 逻辑窗口尺寸，让触屏模式控件更大、键鼠模式信息更多 | 已实现；iPad 待验证 |
| 缩放与精确操控 | 双指双击在 1× 与用户配置的 1.5×/2× 间切换；放大后默认移动视口，输入坐标同步映射到裁剪后的源纹理 | 已实现并有数学单测；原生 magnify 待验证 |
| 直接触控与触控板 | 单指可直接点控；也可把玻璃当相对触控板；妙控键盘指针始终保持绝对坐标 | 已实现；设备兼容性待验证 |
| 全屏桌面手势 | 全屏工作区的屏幕虚拟触控板识别三指方向手势，发送一次性 macOS 桌面命令；外接妙控板保留 iPadOS 系统三指手势 | 规划；桌面命令路径与设备输入边界待验证 |
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
  └─ Scene 顶部语义菜单 / 触摸 / 全屏桌面手势 / 妙控键盘 / 拖放 / 剪贴板
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

### 3. iPadOS 16.3.1 台前调度档位的 Source 与 RE 证据

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

因此当前把密集尺寸档位列为高可行性、RE-confirmed 工作项，同时保留设备运行门槛：记录原始数组、证明 hook 命中、证明 `UIWindowScene.bounds` 采用新增档位，并完成 safe area、输入坐标、键盘、拖放和四窗稳定性回归。TrollPad 的 150 point 下限不能提升为 MacWS 的已证实安全不变量。

### 4. 本地运行 probe 的边界

开发 Mac 为 macOS 26.3.1，不是目标 macOS 13.4 chroot。两种 private flag 的 create/start 都返回 `CGDisplayStreamStart == 0`，但三秒内没有 frame callback。

这个结果只确认本机接受当前参数形状；它不能证明 macOS 13.4 chroot 会出帧，不能证明 IOSurface 能跨到 iPad Host，也不能用于推断性能。

### 5. 等待 iPad 的运行确认

- macOS 13.4 单窗 stream 在目标 bootstrap/session 下开始并持续回调。
- IOSurface Mach right 从 chroot 进入 iPadOS Host，且在原生 AGX device 上成功创建纹理。
- 四个前台 Scene 在台前调度下持续稳定。
- 记录原始 `gridWidths` / `gridHeights`，启用密集档位后确认最终 `UIWindowScene.bounds` 采用新增尺寸，而不是只有窗口装饰或 surface 发生缩放。
- 验证密集档位的系统级影响和 Scene 隔离；非 MacWS 应用不得因全局候选数组修改出现布局、safe area、键盘、拖放或触摸命中回归。
- AppKit 动态最小尺寸、固定尺寸窗口和 density resize 的实际行为。
- 缩放后的四角点击、拖动、滚动、软键盘和妙控键盘输入一致性。
- 全屏屏幕三指候选、桌面命令 capability/result，以及外接妙控板三指是否被 iPadOS 截获的输入日志。
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
8. 在原始档位之间选择一个新增密集档位：窗口装饰、`UIWindowScene.bounds`、Host drawable、macOS 目标 frame 和输入坐标必须最终一致；不能只是拉伸旧画面。
9. 新增档位小于当前应用门槛：只出现整窗遮罩，菜单和 Host 控制入口仍可用；放大到门槛后只发生一次合并后的最终重排。
10. 同时打开 MacWS 与普通 iPad 应用反复 resize：若实现尚为全局实验开关，必须单列记录普通应用的 geometry/safe-area 回归；实现 Scene 隔离后则验证普通应用仍只使用系统原始策略。

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

- 最小尺寸遮罩、触屏密度、二段式放大、双指路由和单指点击/拖动/长按右键在三类应用通过。
- Photos/Safari 的原生 magnify 在真实事件注入路径确认后作为独立增量验收，不阻塞 Host 视口放大能力。
- 修复只能发生在产生错误状态的上游，不接受输入常量偏移补丁掩盖几何问题。

### M3：妙控键盘与四窗

- 键鼠高密度、指针、键盘、滚动、快捷键通过。
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
- 不为超出单窗 capture 范围的右键菜单做视口追踪。
- 不突破 iPadOS 同时四个前台窗口的产品上限。
- 不用跳过 assert、伪造成功返回或零对象 stub 换取表面“稳定”。
