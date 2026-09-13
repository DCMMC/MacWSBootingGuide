# macPad 生产就绪审计（2026-09-12）

## 结论与部署边界

目前仍应标为 **受控测试版，不是已通过验收的生产发布版**。
这不否定已经工作的窗口、输入和跨应用拖放；不足主要在冷启动成本、
异常恢复、默认诊断开销以及可重复的发布验收。

用户本次重启后无法启动的阻断已单独修复并部署，见
[冷启动证据与验收](evidence/coldboot-windowing-readiness-20260912.md)。
实际观察到 Terminal 画面和 bash 子进程，没有重启 SpringBoard。
这里记录的其余生产审计代码仅完成本地验证，**未部署到 iPad**，也未提交/push。
不能把本地构建成功当作设备性能或稳定性验收。

## 已实施的默认值收紧（本地）

| 改动 | 依据、行为与限制 |
| --- | --- |
| 统一生产编译默认值 | 新增 `config/production.mk`，根工程和 35 个顶层子项目在 Theos common.mk 前加载；默认 `FINALPACKAGE=1 OPTFLAG=-O2`。保留符号不再意外选择 `-O0`。显式 `DEBUG=1` 仍可启用调试构建。既有正式构建脚本本来已显式传 `-O2`，不声称它们原先都未优化。 |
| Host 高频诊断调用点默认关闭 | 尺寸同步、菜单/互操作状态和剪贴板类型枚举等细粒度 trace 改为惰性门控，关闭时不构造日志参数。必要启动、错误和首次呈现记录保留。 |
| Host 日志异步且有预算 | 旧实现每条 `NSLog` 加锁并同步打开/关闭文件；本次改为后台串行写入，最多 128 条待写记录，每条截断至 4096 UTF-16 单元，约 4 MiB 轮换一次，保留一个历史文件。溢出/写入失败累计丢弃计数；不承诺进程突然退出时最后几条异步日志必定落盘。升级前既有大日志会先成为历史文件，不主动删除。 |
| SpringBoard 窗口诊断默认关闭 | 窗口 trace、方法清单构造和辅助尺寸统计文件改为显式开关。初始尺寸、事务结果、当前 PID/版本与观察者就绪见证仍无条件发布；未修改手势、窗口约束、绘制或回弹策略。 |
| 关闭性能统计时减少每帧工作 | `recordBaseTransportFinalComposite` 在统计未启用时直接返回，不再每帧拿锁。其他监控内存/HUD 的惰性分配尚未做。 |
| 可执行默认值检查 | 运行开关审计不仅检查清单登记，还检查打包目录和根 Makefile 复制的可选 launch job，拒绝 `production=off` 的环境变量。保留 Steam 三个显式 `SDL_JOYSTICK_*=0` 的兼容配置，其余禁用变量即便为 `0` 也拒绝，避免遗留 `getenv` 按存在性判断。临时和生成目录不参与扫描。 |

新的 Host / Windowing 开关只接受 `1`、`true`、`yes`、`on`（字母大小写不敏感），
缺省、空值、`0`、其他值均关闭。开关在所属进程启动时读取一次：
`MACWS_HOST_DIAGNOSTICS` 只启用 Host trace，
`MACWS_WINDOWING_DIAGNOSTICS` 只启用窗口插件 trace。
启用应通过独立诊断启动环境，不写入生产 launch job。
不要为了开日志反复 respring。Host 原有全局诊断/单独触摸见证仍可显式启用；
运行中已缓存的开关不能仅靠删除文件撤销，需要在合适时机重新启动所属进程。

## 尚需优化，按优先级排序

### P1：冷启动恢复信任缓存耗时

**runtime-confirmed via MacWSStartup.log**：

```text
[macos_gui] Application trust closure ready (bundles=12 Mach-O images=1067).
[macos_gui] Cold-boot trust closure ready (registered=309 existing CodeDirectories).
[macos_gui] TIMING gui-start stage=trust seconds=452 total=469
[macos_gui] TIMING gui-start stage=services seconds=57 total=526
```

启动阻断已解除，耗时没有解决。`restore_application_bundle_trust` 在首个桌面前
遍历整套应用；同次启动有断点缓存，但每次设备重启仍恢复完整集合。
建议将基础桌面依赖与非默认应用拆开，后者在首次打开前恢复；对未变化二进制维护
可验证的 CodeDirectory 清单，再批量恢复。必须覆盖应用更新、多架构、异常中断和
重启后的失效规则。**不能跳过 trustcache 校验或伪造完成标记。**

### P1：断连时剪贴板重复工作

本次运行观察到同一 changeCount `20814` 在 `1789221075.671`、
`1789221076.098`、`1789221076.371` 连续提交失败，记录在设备 `MacWSHost.log`。
源码 `MacWSInteropClient.m` 的 750 ms 元数据轮询和失败后的 500 ms 重试会重新
进入内容归档路径。重复失败是运行时事实；实际 CPU、临时文件增长量尚未测量。

建议每个剪贴板版本只保留一个待发布任务/有效快照，用连接恢复事件加有上限的退避
重试；新版本替换旧版本，并明确暂存文件的释放责任。需用文本、多文件、Notes 图片、
服务退出/重连和多 scene 场景验收。本次仅关闭对应 trace，**没有修改重试行为**。

### P1：发布验收与默认开关管理仍不完整

目前的测试主要是源码合同检查，无法证明动画、毛玻璃、触控和 Stage Manager 分组
正确。应将「启动请求完成 → 协议往返 → 窗口目录 → 实际非空画面 → 输入后的画面变化」
组成连续验收；覆盖冷启动、热启动、服务重连和固定/单轴尺寸窗口。设备反复重启
不能替代验收。ABI 构建检查和测试应接入 CI/打包门禁；本次审计脚本还需手动执行。

当前运行时 `production_preflight` 仍使用单独的诊断 deny-list，覆盖范围与清单不完全
相同；构建审计也无法知道已加载进程的缓存开关或用户手动留下的所有 marker。
后续应由清单生成构建、启动、诊断会话结束三套一致检查，避免再发生两端契约漂移。
本次没有宣称已证明全工程零诊断开销。

### P2：延迟分配性能监控对象

静态检查发现每个 scene 初始化时，`MacWSPerformanceMonitor` 即创建统计数组、
毛玻璃 HUD 和标签，即使 HUD 默认关闭。建议仅在明确开启统计时分配大块样本与 HUD，
关闭后释放；先测量多窗口常驻内存收益。普通拖放准备已在后台队列执行同步 XPC 等待，
不能将其错误归因为正常拖放必然阻塞主线程；部分 `test-*` 诊断入口仍同步等待，
生产版应单独约束这些测试入口。

### P2：按协议边界拆分大文件

`mac_hooks.m` 约 2.2 万行、AppInputBridge 约 1.1 万行，Host 主文件、MetalView
和 hostd 也分别有数千行。建议优先拆分启动/信任缓存、scene 尺寸事务、输入手势、
剪贴板暂存和渲染生命周期，各自拥有协议版本和行为测试，而非一次性大重写。
硬编码二进制适配应按系统版本/UUID 分组，明确支持矩阵和拒绝加载条件。
仓库早期说明与现有代码状态已存在偏差，应维护一份当前架构与发布运行手册。

IOSurface 租约、只保留最新帧、在途帧限额、空闲时停止绘制等现有机制应保留。
不要通过移除完成回调、锁、协议检查或全局断言来制造「更快/不崩」的假象。

## 本次验证结果及边界

- `python3 -m unittest discover -s misc -p 'test_*.py'`：97 项通过。
  含 10 项执行真实 bash 就绪谓词的冷启动回归，以及 10 项生产默认值检查；
  后者包含编译并运行真实布尔开关解析器/惰性日志宏的 Objective-C 小程序。
- `python3 misc/audit_runtime_switches.py`：通过，241 个环境变量名、58 个源码 flag、
  370 条已登记项，并检查打包 plist 不携带禁用环境开关。
- Host arm64、Windowing arm64/arm64e 本地构建通过。
  使用现有 `GO_EASY_ON_ME=1`：严格构建仍遇到旧 `iosclear_ref.m` 的
  `kIOSurfaceIsGlobal` 弃用警告；还不能宣称全仓库无警告构建。
- 实际 Theos 展开值：`FINALPACKAGE=1 OPTFLAG=-O2 SCHEMA=DEFAULT`；
  显式 `DEBUG=1` 时恢复 `SCHEMA=DEFAULT DEBUG` 和 `-DDEBUG -O0`。
- `dyld_info -arch arm64e -fixups`：178 个 `__cfstring` ISA 绑定均为
  `auth-bind ... key=DA`，没有普通未认证 ISA 绑定。字符数据的普通 rebase 正常。
- `bash -n`、`git diff --check` 通过。
- 未执行全包重建、生产审计二进制部署或长时间 CPU/GPU/内存 A/B 验收；
  没有可支持百分比性能提升的测量。冷启动仅本次用户已重启后的系统完成验收，
  不等同于多轮重启稳定性证明。
