# 插件性能开发与排查

每个插件都要对自己的 CPU、内存、GPU、磁盘、网络、后台唤醒和宿主响应负责。轻量插件至少确认闲置与停用后没有持续工作；图像、录屏、模型、音视频、批处理、设备共享等高开销插件，需要记录代表性负载下的资源预算、峰值与回收结果。

当前原生插件与宿主同进程，活动监视器不能直接把内存分摊给每个插件。先停用其他插件，在同一构建与输入下比较“宿主基线 → 目标插件 → 操作结束 → 停用”的变化；另记录相关 helper、WebKit 内容进程与系统服务。多个插件并行时再检查资源叠加，不能把整个宿主的占用当成某一个插件的占用。

## 先定义预算与复现条件

开发前说明正常输入、最大输入、并发数量、目标延迟、允许的缓存大小、持续后台工作和停止条件。预算基于实际功能与设备，不给所有插件套相同的内存上限。

记录 Mac 型号、芯片、内存、macOS、提交或版本、构建配置和输入规模。性能测量使用 Release 或等价优化的本地可剖析构建；Debug、Sanitizer、屏幕录制、热状态、冷暖缓存不同的结果不能直接比较。不要把工具附加失败、未采样或未运行的项目填成零。

一次有效复现至少覆盖：

1. 宿主空闲，插件停用，记录基线。
2. 安装并启用插件，但不执行任务，确认不会提前加载大型模型、解码所有媒体或启动忙轮询。
3. 执行正常输入与接近声明上限的输入；持续任务覆盖足够时长，观察占用是否随时间增长。
4. 完成、取消、报错、撤销权限、禁用、卸载，观察任务、队列、缓存、设备与 helper 是否停止。
5. 重复同一“开始—结束”流程，例如 10 次，区分首次初始化、可回收缓存与持续累积；长运行功能还要做持续负载测试。

## 观察什么

| 现象 | 先记录 | 重点检查 |
| --- | --- | --- |
| 内存峰值很高 | physical footprint、峰值增量、分配调用栈、输入规模 | 解码后的像素、格式转换副本、视频帧、模型、GPU / IOSurface 资源、同时在途任务 |
| 多次操作后持续增长 | 每轮结束后的稳定占用、存活对象与持有链 | Task、闭包、观察者、Combine 订阅、窗口、队列与无界缓存 |
| 空闲时 CPU 仍高 | 空闲采样、线程栈、唤醒与计时器 | 忙轮询、重复刷新、未取消任务、事件反馈循环 |
| 操作慢或界面卡住 | 延迟分布、主线程调用栈、分阶段耗时 | 主线程解码 / 编码 / 同步 I/O、锁等待、优先级反转、SwiftUI 重复计算 |
| GPU / 能耗偏高 | GPU 时间、纹理 / buffer 存活、屏幕刷新 | 不可见内容持续渲染、重复建上下文、无界中间纹理、过高帧率 |
| 磁盘 / 网络偏高 | 字节数、频率、重试、临时目录大小 | 全量重复写入、相同资源反复下载、无限重试、未清理临时文件 |

RSS、虚拟地址空间与 physical footprint 口径不同；不要仅以虚拟内存大小判断泄漏。操作结束后 RSS 未立即下降也不能单独证明泄漏，需要结合存活分配、缓存上限、系统回收和多轮趋势判断。

## 用 Instruments 定位到代码

在完整 Xcode 中选择 Product → Profile（⌘I），使用可附加的本地开发签名配置。正式发行包的签名可能限制附加；不要为剖析把发行 entitlement 改成允许调试。

- **Allocations**：对同一操作分阶段记录，按分配大小、数量与存活情况定位调用栈；用 generation 对比反复操作后仍存活的对象。
- **Leaks 与 Memory Graph**：检查泄漏和持有关系。ARC 循环、遗留任务、缓存或框架资源不一定都被 Leaks 报告，不能以“0 leaks”代替内存分析。
- **Time Profiler**：采集正常、慢操作与空闲阶段，按线程和调用树确认最耗时的方法；卡顿优先检查主线程，不凭猜测把所有代码挪到后台。
- **System Trace / Hangs / Thread Performance Checker**：根据问题检查线程阻塞、唤醒、锁与响应性；有 Metal 工作负载时检查 GPU 分配与提交。
- **Points of Interest / OSSignposter**：标记插件 ID、操作 ID 和“读取—解码—处理—编码—保存”等阶段，以便把峰值和调用栈关联起来。标记不写用户内容或密钥。

Sanitizer 用于发现内存破坏、竞态等正确性问题，会改变时序与资源开销；修复后关闭额外诊断，再用相同负载比较性能。

## 只有命令行工具时

先从活动监视器或 `pgrep -fl TietiezhiTools` 确认实际进程，手动设置目标 PID。以下命令用于已有进程，不申请屏幕、设备权限，也不终止进程；输出只保存在被忽略的本地 `dist/`。

```bash
plugin_pid=12345  # 替换成实际 PID
mkdir -p dist/performance
/bin/ps -p "$plugin_pid" -o pid=,pcpu=,rss=,etime=,command=
/usr/bin/footprint -p "$plugin_pid" > dist/performance/footprint.txt
/usr/bin/vmmap -summary "$plugin_pid" > dist/performance/vmmap.txt
/usr/bin/sample "$plugin_pid" 5 1 -file dist/performance/sample.txt
/usr/bin/leaks --noContent "$plugin_pid" > dist/performance/leaks.txt
```

`ps` 的 RSS 是 KiB，CPU 百分比不能当成单次任务耗时；命令行快照也不等于捕获了峰值。用相同流程在各阶段采样，保留时间与操作记录。签名或系统限制导致无法读取时，保留失败说明，改用可剖析的本地构建或完整 Xcode，不修改 TCC、SIP 或全局系统保护。

## 开发时控制资源

- **先限制再分配**：限制像素、帧、输入字节与并发数；预览用缩略图、按需解码。80,000,000 像素的单份 RGBA8 原始数据就约 305 MiB，压缩文件大小不能代表处理时占用。
- **使用有界流水线**：长图、长视频、网络与音频采用分段、流式和背压；队列满时采用明确的丢弃、暂停或拒绝策略，不无限堆积。3840 × 2160 的 RGBA8 单帧约 31.6 MiB，保留多份会快速放大峰值。
- **明确缓存所有权**：缓存有字节 / 时间预算与淘汰策略；窗口、模型、解码器、纹理、临时文件有可说明的生命周期。大批量 Objective-C / Core Foundation 临时对象必要时分批使用 autoreleasepool。
- **限定并发与刷新**：不为每帧、每个输入事件启动无界 Task。合并重复工作，取消过期预览，限制刷新与重试，按事件驱动后台任务。实时回调避免阻塞 I/O 和不可预测的工作。
- **确认停止真实生效**：取消任务并等待资源拥有者结束，解除订阅和监听，关闭文件、设备、连接及子进程；不能仅隐藏 UI 或更改启停文案。
- **用数据验证优化**：相同设备、输入与配置比较修改前后。峰值受控但速度、画质或功能退化也要报告；不靠减少实际测试负载制造改善。

## 提交与发布证据

每个插件 README 提供“性能与资源”说明：高开销路径、预算或上限、缓存与清理行为、复现步骤、测试环境、实际观察及未测项。纯声明式轻量插件可简要说明不常驻后台，并记录空闲和启停检查；涉及大资源或明显性能变更时提交前后数据与调用栈结论。

建议记录表：

| 场景 / 输入 | 基线 footprint | 峰值 / 增量 | 空闲 / 任务 CPU | 耗时 | 停止后 / 多轮趋势 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| 正常、最大输入、持续运行、取消 / 禁用 | 实测值或未测 | 实测值或未测 | 注明采样口径 | 冷 / 暖缓存分开 | 稳定、回收或持续增长 | 修复与剩余限制 |

禁止无界队列、随操作持续累积的无主资源、停用后持续采集或忙循环。发现这类回归先修复。没有对应测量时标记未测，不宣称“零开销”“无泄漏”或“低内存已验证”。原始 trace / memgraph 可能包含路径和用户数据，公开前只保留可共享的复现与去标识摘要。

## 参考

- Apple：[Gathering information about memory use](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use)，介绍内存报告、Memory Graph 与 Allocations。
- Apple：[Diagnosing and resolving bugs in your running app](https://developer.apple.com/documentation/xcode/diagnosing-and-resolving-bugs-in-your-running-app)，介绍资源观察与持续增长的诊断。
- Apple：[Addressing CPU bottlenecks](https://developer.apple.com/documentation/xcode/addressing-cpu-bottlenecks)，介绍 CPU 分析及 signpost 关联。
- Apple：[Diagnosing memory, thread, and crash issues early](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early)，说明诊断工具和额外开销。
