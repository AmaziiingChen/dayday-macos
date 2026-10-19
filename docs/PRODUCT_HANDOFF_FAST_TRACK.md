# Dayday 产品交接与快速成形开发手册

- **状态日期：** 2026-08-01
- **目标读者：** 接手 Dayday 后续开发的新 Codex、OpenCode 或人工开发者
- **当前快速开发分支：** `codex/fast-product-shape`
- **当前代码检查点：** `efd2c25` (`design: compact shared page chrome`)
- **只读恢复标签：** `fast-track-baseline-20260801`（快速开发开始前的安全后手）
- **远程仓库：** `https://github.com/AmaziiingChen/Dayday.git`（private）
- **产品版本：** `0.1.0` 开发中

## 1. 这份文档解决什么问题

Dayday 已经投入了大量时间建立隐私边界、领域模型、采集器、SQLite 数据层、测试体系和
SwiftUI 原型，但还没有打通一条普通用户可以每天使用的完整产品路径。下一阶段的目标不是
继续横向扩充抽象，而是用更短的反馈周期尽快看见真实产品形态：启动 App 后能够持续记录，
Today 能展示真实时间线，系统能构造 Session/Activity，并能使用用户自己的模型 API 生成和
保存工作日报。

本手册将当前事实分为四类：

1. 已经集成且经过验证的生产基础；
2. 已存在但只是契约、样板或占位的能力；
3. v0.1 仍缺失的真实产品路径；
4. 为加快开发而采用的精简验证策略，以及出现 Bug 时的恢复方法。

它应与以下权威文件一起使用：

- `AGENTS.md`：不可违反的工程与隐私规则；
- `docs/HANDOFF_OPENCODE.md`：最近一次保守的工程验证状态；
- `docs/AGENT_PROTOCOL.md`：多任务协作和共享契约规则；
- `docs/PRODUCT_SPEC.md`：完整产品决策；
- `docs/RESEARCH_REFERENCES.md`：竞品、开源项目、设计转译与源码许可证边界；
- `docs/adr/0018-h1-production-collection-and-durable-projections.md`：H1 生产采集与持久化；
- `docs/V0_1_EXECUTION_PLAN.md`：完整 v0.1 工作树。

如果这些文档与用户在新对话中的明确决定冲突，以用户最新决定为准，并把新决定写回文档。

## 2. 当前可恢复的 Git 基线

### 2.1 当前状态

在本手册建立之前，仓库已经完成一次干净检查点：

- 本地分支与 `origin/opencode/v0-1-recovery` 同步；
- 工作树干净；
- H1 运行时提交为 `090d5d9`；
- H1 权威文档检查点为 `4f22a89`；
- 菜单栏视觉改动为 `cfca1e7`；
- 重新生成且可构建的 Xcode 工程为 `c6a1aad`。

只读标签 `fast-track-baseline-20260801` 已建立并推送，包含快速开发开始前的干净代码基线和
本交接手册初版。该标签是回退与 bisect 后手，不应移动或改写。接续当前产品形态时应以远程
`codex/fast-product-shape` 分支为准；只有需要从快速开发前重新试验时才从恢复标签建分支。

### 2.2 已验证结果

- `./scripts/test`：**367 项测试，37 个测试套件通过**；
- SwiftPM Debug/Release：通过；
- Q0 六项质量门：通过；
- unsigned Xcode Release：通过；
- 当前菜单栏改动合入后的 unsigned Xcode Debug：通过；
- 当前 Debug App：
  `.build/xcode-derived/Build/Products/Debug/Dayday.app`；
- 当前 Bundle ID：`app.dayday.local`；
- 当前最低系统：macOS 14；
- 当前版本：`0.1.0 (1)`。

### 2.3 恢复原则

后续开发即使为了速度允许出现较多 Bug，也必须保留以下后手：

- 每个用户可见的纵向切片单独提交；
- 不使用 `git reset --hard` 或覆盖用户工作；
- 不改写或强制推送恢复标签；
- 重大试验在独立分支进行；
- 在数据库 schema、权限语义或隐私规则变化前先建立新检查点；
- 用 `git revert <commit>` 撤销已经共享的坏提交；
- 用 `git bisect` 在小提交序列中定位回归；
- 开发数据库视为可丢弃测试数据，真实 dogfood 数据启用后必须先导出或备份再跑迁移试验。

## 3. 产品目标与不可妥协边界

Dayday 是一个面向知识工作者的、本地优先的个人工作记忆与工作日报助手。它优先服务 macOS，
以后再考虑 Windows 和手机端。用户无需订阅，由用户自己提供模型 API。

核心产品体验是：

```text
安静记录客观工作事实
→ 组织成可解释的时间线、Session 和 Activity
→ 用户查看或修正
→ AI 基于工作数据生成自由形式工作日报
→ 日记作为独立的个人书写空间存在
```

必须始终遵守：

- Local-first、BYOK、无远程遥测、无隐藏上传；
- 工作日报和个人日记是同级但隔离的产物；
- 工作日报生成永远不能读取日记正文或情绪记录；
- 客观观察、AI 推断、用户修正必须可区分；
- 不生成“专注度”“生产力”“工作质量”等评分；
- 不保存输入文字、按键顺序、精确鼠标事件历史；
- 不默认保存原始截图；原始分辨率画面只允许短暂存在于内存；
- 不保存密码、安全输入、Chrome 无痕上下文、查询参数、页面正文；
- 暂停、禁用、权限撤销、锁屏、休眠等负向事实永远优先；
- 自动启动、刷新、唤醒和恢复不得弹出 TCC 权限请求；
- 用户必须从明确交互路径发起系统权限请求。

## 4. 已完成并集成的能力

### 4.1 原生 App 与交互框架

- Swift 6、SwiftUI、macOS 14+、Apple Silicon first；
- 主窗口和原生 `MenuBarExtra`；
- 主窗口与菜单栏共享运行状态模型；
- Today、Journal、Insights、Settings、History 等页面骨架；
- 权限首次引导和逐采集器产品同意界面；
- Debug Development Preview，可切换示例状态；
- 菜单栏已经采用紧凑布局：状态、记录条件、最近 90 分钟空状态概览、快速记录、打开今日；
- 菜单栏入场动画遵循 Reduce Motion；
- Xcode 项目已重新生成，DesignSystem、DesignSpecimen、Presentation 源文件已进入 App target。

当前 App 框架能启动和浏览，但它仍主要展示预检、样板或空状态，不能据此宣称生产采集已运行。

### 4.2 设计系统与 Today 展示语法

- 视觉主方向：Evidence Thread / 证据脉络；
- 当前工艺基线：Mineral Workbench / 矿物工作台；
- Today 主时间线采用纵向时间轴；
- 默认工作日边界为本地 04:00 到次日 04:00；
- 客观事实、Session、推断 Activity、生命周期断点和多显示器来源有独立语义；
- 已有语义色、间距、圆角、层次和动画 token；
- 支持深色、高对比度、Reduce Motion、Reduce Transparency；
- 时间可视化有文本与 VoiceOver 描述基础；
- Today objective-only presentation adapter 已集成，能生成确定性的展示描述符。

这些设计和 adapter 尚未完全连接真实数据库与生产运行状态。

### 4.3 权限、产品同意与生命周期

- 产品同意与 macOS TCC 权限分离；
- 每个采集器拥有独立的未确认、启用、暂停、禁用和续期状态；
- 全局暂停与采集器级暂停分离；
- TCC 请求只能来自明确的用户动作；
- 非提示式权限预检；
- 屏幕、Accessibility、Input Monitoring、日历等权限类别基础；
- 系统睡眠、唤醒、会话、屏幕可用性和显示器拓扑边界；
- 屏幕采集运行时包含授权撤销纪元，关闭迟到启动和后端泄漏竞态；
- 暂停/禁用意图支持 owner-only 崩溃安全 marker 和重放语义。

### 4.4 隐私安全的客观采集基础

- 显示器枚举、身份协调、拓扑修订和多显示器变化；
- 前台应用和窗口上下文采集；
- Accessibility 拒绝时零内容输出；
- 密码管理器、登录和安全角色等强制排除；
- 原始 bundle identifier 在 Capture 内部处理，不进入持久化或日志；
- 应用身份使用本地 salt 派生不透明 ID；
- 普通应用的经过过滤的显示名称、窗口标题和文件名提示可以进入 H1；
- Chrome Stable/Beta/Canary/Chromium 在可信扩展接入前只保留不透明应用身份，不保存标题；
- 键盘和鼠标只产生非内容型聚合，不产生字符、顺序和精确轨迹；
- ScreenCaptureKit 内存帧流和背压基础，不默认持久化画面。

### 4.5 H1 生产采集运行时

`090d5d9` 已实现并通过独立复审：

- 有界同步 mailbox；
- 普通容量和关键边界保留容量；
- 一个串行 worker 是持久化 lane 的唯一调用者；
- 运行状态和历史修订为多订阅者 AsyncStream；
- 系统唤醒 latch 和独立 pause reason 集合；
- App/window 原始值只在 pending/in-flight 内存中短暂存在；
- Accessibility 实时丢失时关闭内容入口；
- 暂停、禁用和失败时立即关闭 admission；
- shutdown 排空已经接纳的工作并拒绝迟到回调；
- 队列饱和时保留 FIFO，并写入终止性的资源压力状态；
- 存储、服务和不变量失败转为安全的终止状态；
- 生命周期等价通知去重；
- 同一进程内负向控制保留动作开始时的时间和时区；
- 采集运行时不依赖 Storage 具体实现，依赖方向保持正确。

重要限制：H1 runtime 已经存在，但正式 App 启动流程尚未构造并运行它。

### 4.6 SQLite 与本地数据层

- owner-only Application Support 路径；
- 符号链接、硬链接、ACL 和侧车文件安全检查；
- SQLite WAL + `synchronous=FULL`；
- 并发首次打开和 WAL 收敛竞态修复；
- Objective namespace v4；
- Input aggregate namespace v2；
- Collection consent/control namespace v1；
- ObjectiveEvent 精确日期往返和稳定半开区间查询；
- ApplicationContextRecord；
- CollectorStateRecord；
- content-free CollectionSuppressionRecord；
- InputAggregate 和 open checkpoint；
- consent/global control CAS 与 revision；
- stop intent marker 创建、同步、重放和冲突检测；
- `ProductionDataStore.verifyWritable()` 真实 SQLite 写事务和 marker 目录探测；
- 数据库 schema 指纹、未知版本、异常 enum 和投影所有权均 fail closed。

### 4.7 Session、Activity、证据和个人产物契约

已经完成的是严格领域契约和测试，并非完整业务实现：

- Session 的时间、显示器、成员事实和硬边界；
- Activity、来源、置信区间、review state、lineage；
- supporting/conflicting evidence；
- 客观证据和 AI 推断角色分离；
- WorkReport、revision、finalization、context allowlist；
- JournalEntry 原文不可覆盖，AI 派生版本独立；
- MoodEntry 五点主观量表；
- 城市级 WeatherSnapshot；
- 图片和网页附件的安全边界；
- WorkReport/Journal 严格隔离测试。

## 5. 已存在但不能当作产品完成的部分

以下内容很容易在浏览代码或 UI 时被误判为“已经做完”：

| 表面 | 当前真实状态 |
| --- | --- |
| Today 时间线 | 有 adapter、样板和空状态，没有连接生产数据库 |
| 菜单栏最近 90 分钟 | 目前是有明确标记的空状态，不是真实近期事实 |
| 快速记录 | 按钮存在但禁用 |
| 工作日报 | 有 Core 契约和 UI 占位，没有模型调用与持久化流程 |
| 日记 | 有交互原型和 Core 契约，正文尚未持久化 |
| Activity | 有闭合契约，没有生产 derivation job 和 repository |
| AI | `DaydayAI` 仍是占位，没有 provider、Keychain、usage ledger |
| Understanding | `DaydayUnderstanding` 仍是占位，没有生产 OCR/Session/Activity 管线 |
| Integrations | Chrome 协议核心存在，其余大量能力仍是占位 |
| 屏幕理解 | 有内存帧流，没有生产 evidence consumer，不应持续启动流 |
| 应用记录/热力图/历史报告 | 页面或模型基础存在，没有完整真实数据闭环 |
| 权限引导 | UI 和状态机存在，但正式 App 生产启动编排尚未接好 |

新开发窗口必须在 UI 文案中继续区分“示例”“空状态”“预检”和“真实本地数据”，不得用
看似真实的指标掩盖尚未连接的功能。

## 6. 距离可用 v0.1 还缺什么

### 6.1 P0：生产 App 启动和控制编排

这是最优先工作，也是所有真实产品页面的入口。

目标启动顺序：

```text
App 启动
→ 后台打开 ProductionDataStore
→ verifyWritable
→ 重放 unresolved stop intents
→ 加载 consent 和 global control
→ 恢复/完成 input checkpoints（接入对应采集器时）
→ 非提示式权限预检
→ 构造 H1CollectionRuntime
→ 订阅 status/history
→ start
```

关闭顺序：取消 bootstrap/订阅任务，等待 H1 shutdown，再关闭其他运行服务。关闭主窗口不等于
退出采集，只有应用终止才 shutdown。

必须实现：

- opening、ready、paused、permission-required、degraded、failure 等真实状态；
- 任何早期启动失败都阻止后续 producer admission；
- marker/control persistence failure 留在安全 hold 状态；
- App 负责把失败和修复路径解释给用户；
- App 不接触原始 AX、frame、键盘或鼠标事件。

### 6.2 P0：Today 和菜单栏接入真实数据

- 从当前工作日的 04:00 边界查询 ObjectiveEvent；
- 使用已集成 adapter 构造纵向 Evidence Thread；
- 数据 fetch state 与 collector health 分离；
- 即使当前暂停或权限缺失，也继续展示已持久化的历史事实；
- App/window 上下文权限主要依赖 Accessibility，不应让屏幕权限错误遮蔽全部事实；
- history revision 更新后刷新当前工作日；
- 菜单栏显示最近事实、真实状态和最近 60–90 分钟概览；
- Quick Record 可以先做本地手工工作事实或工作笔记，不必等待 AI。

### 6.3 P0：Session/Activity 生产构造与持久化

- 从真实 H1 events 构造 Session；
- 处理硬边界、暂停、锁屏、睡眠和工作日边界；
- 不把不同显示器事实错误缝成一个单显示器 Session；
- Activity 可以先用确定性规则构造，AI 只是后续增强；
- 推断必须记录证据、来源、置信区间和算法版本；
- 支持用户修正，不覆盖原始事实；
- 增加 repository、schema migration、range fetch 和重建策略；
- Today 展开 Activity 时能查看证据与推断原因。

### 6.4 P0：BYOK 自由形式工作日报

- Keychain 保存 API Key，数据库只保存 provider 配置引用；
- 优先实现一个 OpenAI-compatible provider，可兼容用户常用模型服务；
- 支持 endpoint、model、API Key、timeout；
- 请求前构造严格 `WorkReportContext`，不能读取 Journal/Mood；
- 默认不使用固定结构化模板，让模型根据当天事实自由总结；
- 支持可选自定义指令；
- 流式或明确进度状态；
- 失败、取消、重试和超时；
- usage/token 记录，不能记录 API Key 或完整敏感 prompt；
- 保存 draft、用户修改、final revision；
- 历史查看与 Markdown 导出。

完成以上四段后，Dayday 才具备第一条真实可用闭环。

### 6.5 P1：日记、情绪和天气

- 日记正文持久化和自动保存；
- 一天内可以上午、下午、晚上持续追加；
- 日记与工作日报无顺序依赖；
- 原文永远保留；
- AI 整理/润色/续写作为独立可选副本；
- 情绪记录；
- 城市级天气 API 和每日快照；
- 附件；
- 日历和历史浏览。

### 6.6 P1：键鼠与应用分析

- 启动真实 Input Monitoring 聚合采集；
- 可靠恢复 open checkpoint；
- 键盘按键计数与布局热力图；
- 鼠标点击热区、移动距离和滚动聚合；
- 应用使用时长、切换次数、最长连续前台；
- 时段热力图；
- 日/周/月/自定义范围；
- 无障碍文本表格替代；
- 不保存字符、组合键语义、精确坐标轨迹或按键到应用的敏感关联。

### 6.7 P2：外部集成和维护能力

- Chrome unpacked extension + Native Messaging Host；
- macOS EventKit 日历与提醒事项；
- 钉钉、飞书日程和待办；
- 天气 API；
- 本地受保护 HTTP API/MCP；
- JSON/Markdown 导出；
- 备份、恢复、导入；
- retention、容量预算、证据过期和诊断；
- 手机端录音和灵感同步（后续衍生品）。

## 7. 快速开发策略：少审查，但不放弃恢复能力

### 7.1 目标

下一阶段允许为了更快看到完整产品形态而减少重复审查和过度验证。接受短期内 UI Bug、状态
刷新瑕疵、边缘流程不完整和局部技术债，但不接受隐私泄漏、数据不可逆损坏、权限误请求、
日报读取日记、API Key 泄漏或负向控制失效。

### 7.2 精简后的验证层级

普通低风险切片采用快速门：

- 编译通过；
- 最相关的 focused tests；
- `git diff --check`；
- 手工走通一个主路径；
- 立即形成小提交。

以下切片不必每次运行完整 Q0 或独立模型复审：

- 纯 SwiftUI 页面布局；
- 已有 presentation model 的接线；
- 文案、图标、动画和空状态；
- Debug specimen；
- 无 schema、权限和网络语义变化的本地交互。

在以下检查点再运行全量 `./scripts/test` 和 Release build：

- 完成 App production bootstrap；
- 完成真实 Today；
- 完成 Session/Activity 持久化；
- 完成首个 BYOK 工作日报；
- 准备交给用户进行一天或多天真实使用。

### 7.3 不能省略审查的高风险区域

即使快速开发，也必须对下列改动进行专项测试和至少一次明确审查：

- 数据库 schema 和 migration；
- 删除、清理、retention、备份和恢复；
- TCC 权限请求与自动启动；
- pause/disable/lock/sleep 等负向控制；
- 原始截图、AX、浏览器、输入事件的隐私过滤；
- Keychain、API Key、模型 endpoint 和请求日志；
- provider usage/token 计量；
- WorkReport 与 Journal/Mood 隔离；
- import/export 和本地 API/MCP；
- 任何不可逆操作。

这些区域的审查可以更窄、更有针对性，但不能完全跳过。

### 7.4 推荐提交节奏

每个提交应当能回答“用户现在多获得了什么”：

```text
1. boot: open and probe production store
2. boot: replay controls and construct H1
3. today: fetch and render real objective events
4. menu: show live collection state and recent facts
5. h2: derive and persist first deterministic sessions
6. h2: derive provisional activities with provenance
7. ai: save one provider credential in Keychain
8. report: generate and persist first real work-report draft
9. report: edit, finalize and export Markdown
```

不要把整个 v0.1 塞进一个提交。快速开发依赖小提交提供廉价回滚，而不是依赖每一步都有大量
审查。

### 7.5 并行和文件所有权

如果新窗口再次并行开发：

- 一个窗口负责 App 生产接线；
- 一个窗口负责 H2 Session/Activity；
- 一个窗口负责 BYOK/WorkReport；
- 一个窗口可以做视觉，但只消费冻结的 presentation contract；
- 只有主集成窗口修改 `DaydayCore`、schema、`Package.swift`、`project.yml` 和生成项目文件；
- 同一文件不能被两个活动窗口同时修改；
- 每个窗口从明确 BASE 建分支并返回一个窄提交；
- 快速模式下减少复审次数，不等于允许跨窗口默默改变共享语义。

如果只有一个新窗口开发，则严格按 P0 顺序推进，避免同时铺开多个半完成模块。

## 8. Bug 处理与恢复剧本

### 8.1 UI 或普通逻辑回归

1. 保存失败现场和复现步骤；
2. 找到最近一个用户可见切片提交；
3. 优先修复并添加一个 focused regression test；
4. 如果阻塞主路径，使用 `git revert` 撤销该切片；
5. 不回退整个仓库。

### 8.2 无法定位的回归

确保提交足够小后使用：

```bash
git bisect start
git bisect bad HEAD
git bisect good fast-track-baseline-20260801
```

在每个候选提交运行最小复现命令，定位完成后执行 `git bisect reset`。

### 8.3 数据库或迁移问题

- 立即停止对真实 dogfood 数据继续写入；
- 复制完整数据库及 WAL/SHM 作为诊断副本，不把个人数据提交到 Git；
- 用临时数据库构造最小复现；
- 不用删除数据库掩盖迁移 Bug；
- 修复必须覆盖旧 schema、失败回滚和重新打开；
- 如果新迁移尚未共享，回到恢复标签重做；如果已经共享，增加向前修复迁移。

### 8.4 权限或采集越界

- 第一时间关闭对应 collector admission；
- 不自动再次请求权限；
- 检查日志、数据库和导出中是否出现被禁止字段；
- 用 content sentinel 测试证明零泄漏；
- 在恢复采集前完成专项审查。

### 8.5 模型或 API Key 问题

- 立即取消请求并停止重试；
- 检查 Keychain、日志、数据库、错误提示和导出；
- API Key 只允许出现在内存和 Keychain；
- 如果存在泄漏可能，提示用户轮换 Key；
- WorkReport 请求必须重新验证 Journal/Mood 未进入上下文。

## 9. 新开发窗口的推荐执行路线

### 阶段 A：让 App 真正运行 H1

完成 `APP-BOOT-CONTROL-01`，不要先改视觉。退出条件：启动成功时 H1 真实运行；启动失败时
界面解释准确且没有 producer 启动；应用退出等待 H1 shutdown。

### 阶段 B：让用户看见真实记录

完成 `APP-LIVE-TODAY-01` 和菜单栏真实状态。退出条件：应用切换能在数据库和 Today 看到
经过过滤的客观事实；暂停后不再产生新内容；历史事实仍然可见。

### 阶段 C：形成可读的工作时间线

先实现确定性 Session，再实现 provisional Activity。退出条件：一天的事件不再是离散日志，
而是能解释的工作时段，并能展开证据。

### 阶段 D：生成第一份真实工作日报

先支持一个 OpenAI-compatible BYOK provider。退出条件：用户配置 Key 后，可以基于当天工作
上下文生成自由形式草稿、编辑、保存、定稿和导出 Markdown；日记和情绪内容不在请求中。

### 阶段 E：快速补齐产品形态

在主闭环可用后再实现日记持久化、情绪、天气、应用统计、键鼠热力图、历史和 Insights。
这些功能可以边真实使用边打磨。

## 10. 启动、构建与验证

### 10.1 当前已经构建的 App

```text
<repository-root>/.build/xcode-derived/Build/Products/Debug/Dayday.app
```

启动：

```bash
open .build/xcode-derived/Build/Products/Debug/Dayday.app
```

这是 `LSUIElement` 菜单栏应用，启动后主要查看屏幕顶部状态栏，不一定显示 Dock 图标。

### 10.2 重新生成项目

新增或删除 `Sources/DaydayApp` 文件后运行：

```bash
./scripts/generate-project
```

检查并提交 `Dayday.xcodeproj/project.pbxproj` 的确定性变化。

### 10.3 构建 Debug App

```bash
xcodebuild \
  -project Dayday.xcodeproj \
  -scheme Dayday \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### 10.4 测试

快速切片优先运行：

```bash
swift test --disable-sandbox --filter <RelevantSuite>
git diff --check
```

纵向里程碑运行：

```bash
./scripts/test
swift build --disable-sandbox -c release
```

高风险或准备真实使用时运行 Q0 和 unsigned Xcode Release。

## 11. 当前已知风险和外部验证

- 生产 App 仍没有构造 H1 runtime；
- 当前 Debug App 是本地无付费签名构建，移动或重建后 TCC 身份可能变化；
- 真实 Accessibility 和 Screen Recording 授予/撤销尚未完成系统级验证；
- 睡眠、唤醒、锁屏和多显示器热插拔需要真实 Mac 冒烟；
- 阻塞 I/O 下的应用终止需要手工验证；
- 长时间 CPU、内存、电量、磁盘和队列压力未形成 dogfood 数据；
- Activity derivation、provider、日报、日记和 Insights 仍未形成生产闭环；
- 两周 dogfood 尚未开始，但它不阻塞先完成产品形态；
- 公共签名、公证、自动更新、Mac App Store 和 Windows 均不是当前阻塞项。

## 12. v0.1 的最低验收定义

Dayday v0.1 可以开始个人真实使用，需要至少满足：

1. App 登录后自动在菜单栏运行；
2. 用户逐项确认后，应用能持续采集允许的客观工作事实；
3. 暂停、禁用、锁屏、休眠和权限撤销不会继续写入内容；
4. 重启后数据和控制状态可恢复；
5. Today 能展示真实纵向工作日时间线；
6. 至少能构造可解释的 Session 和 provisional Activity；
7. 用户可以修正推断而不覆盖原始事实；
8. 用户配置自己的 API 后可以生成自由形式工作日报；
9. 日报可以编辑、保存、查看历史并导出 Markdown；
10. 日记和情绪永远不会进入工作日报上下文；
11. 没有原始截图、字符、按键顺序、精确鼠标轨迹或 API Key 泄漏；
12. 连续一天使用没有阻塞性崩溃，随后进入边用边修和两周持续验证。

日记、天气、完整热力图、Chrome 扩展、日历/钉钉/飞书和手机同步可以在第一条闭环后继续
补齐，但领域边界和第一天开始采集的基础数据应尽早保留。

## 13. 新对话可直接使用的启动提示

```text
你正在接手当前 Dayday 仓库根目录。

先完整阅读：
1. AGENTS.md
2. docs/PRODUCT_HANDOFF_FAST_TRACK.md
3. docs/HANDOFF_OPENCODE.md
4. docs/AGENT_PROTOCOL.md
5. docs/RESEARCH_REFERENCES.md 中与当前任务有关的章节
6. 当前里程碑直接引用的 ADR/代码，不要无差别读取全部文档。

先执行 `git fetch --tags origin`。若是接续当前产品开发，从已推送的
`origin/codex/fast-product-shape` 建立自己的分支；若是恢复快速开发前的安全状态，才从
`fast-track-baseline-20260801` 建立分支。检查 git status、当前 HEAD、远程同步和现有 Debug
App。不要重置或覆盖任何用户修改。

开发目标是尽快形成可使用的产品闭环，按以下顺序推进：
APP-BOOT-CONTROL-01 → APP-LIVE-TODAY-01 → Session/Activity → BYOK WorkReport。

采用快速验证策略：普通 UI/接线切片只跑 focused tests、编译、diff check 和主路径手测，
每个用户可见切片小提交；在每个纵向里程碑再跑全量测试和 Release。减少重复审查，但数据库
migration、权限/负向控制、隐私过滤、Keychain/API Key、模型 usage 和 WorkReport/Journal
隔离仍必须专项测试和明确审查。

不要继续建立未连接的抽象。每一步都要说明用户现在获得了什么、真实数据从哪里来、失败时
如何展示，以及如何回到上一干净提交。所有示例和占位数据必须明确标记。

先只执行 APP-BOOT-CONTROL-01。完成后提交、报告验证结果和可启动 App 路径，再进入下一步。
```

## 14. 最终交接结论

Dayday 目前不是“什么都没做完”，也不是“已经可以日常使用”。它已经有一套相当扎实的本地
数据、隐私、权限、采集和领域基础，且通过了大规模自动测试；真正缺失的是把这些基础连接成
用户可感知的产品闭环。

下一阶段应主动接受适量可修复 Bug，以换取更快的真实反馈，但必须用干净 Git 基线、小提交、
里程碑推送和高风险专项审查守住后手。这样即使快速开发分支失败，也能稳定回到本手册记录的
基线，逐个 cherry-pick 有价值的切片或重新实现问题部分。
