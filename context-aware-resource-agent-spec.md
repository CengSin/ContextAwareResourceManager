# Mac 上下文感知资源管家 — 技术规格文档 v1.1

## 0. 文档目的

本文档定义 v1（MVP）与 v2 范围内的产品能力边界、系统架构、数据模型与核心算法，作为开发依据。所有涉及 macOS 权限/API 的判断已在设计讨论阶段做过验证，不重新调研可行性。

---

## 1. 产品定位

一个常驻菜单栏的资源管理工具。核心差异化不是"比 macOS 更会压缩内存"，而是**理解用户当前工作场景，判断哪些进程现在不重要**，并在权限允许的范围内提供诚实的处理手段。

定位表述：**Context-aware resource manager**（不使用 "Memory Optimizer / Compressor" 类命名，避免暗示不存在的能力）。

---

## 2. 能力边界声明（Non-Goals，必须在设计和 UI 文案中始终遵守）

| 能力 | 是否在范围内 | 说明 |
|---|---|---|
| 展示 Memory Pressure / RAM / Swap / Compressed | ✅ | 公开 API，`host_statistics64` 等 |
| 展示 per-process 内存/CPU 占用 | ✅ | `proc_pidinfo` 系接口，需标注"半私有" |
| 判断当前工作场景（Workspace） | ✅ | 应用层信号，规则匹配 |
| 对进程打分（Reclaim Score） | ✅ | 本地规则计算 |
| 降低某进程 CPU 占用 | ✅ | `setpriority()` / `taskpolicy` |
| 冻结/恢复某进程 | ❌ 已停用 | `SIGSTOP` 会卡住有窗 App 的 WindowServer；仅解冻旧版本残留 |
| 退出某进程 | ✅ | `NSRunningApplication.terminate()` |
| **直接压缩/回收其他进程的内存页** | ❌ 永久不可行 | 无公开 API，需要 kernel VM subsystem 权限 |
| **获取其他进程 task port 并 suspend/resume 内存态** | ❌ 永久不可行 | 受 SIP + entitlement 限制 |
| 读取其他 App 的窗口内容/剪贴板等敏感信息 | ❌ 不在范围内 | 隐私边界，非技术限制 |

**UI 文案硬性要求**：任何"优化内存"相关的按钮/提示，其实际动作必须是"退出"或"降低优先级"，不能出现"压缩中""正在释放内存"等暗示直接内存回收的措辞。没有冻结。

---

## 3. 系统架构

```
┌───────────────────────────────────────────────┐
│                   Menu Bar UI                   │
│         (SwiftUI, 常驻图标 + 弹出面板)            │
└───────────────────┬───────────────────────────┘
                     │
┌───────────────────▼───────────────────────────┐
│              Application Coordinator            │
│         (调度各模块，管理生命周期)                  │
└──┬─────────┬─────────┬─────────┬───────────────┘
   │         │         │         │
┌──▼───┐ ┌──▼───┐ ┌───▼────┐ ┌──▼──────┐
│Context│ │System │ │Reclaim │ │ Action  │
│Collect│ │Monitor│ │ Scorer │ │Executor │
│  or   │ │       │ │        │ │         │
└──┬────┘ └──┬────┘ └───┬────┘ └──┬──────┘
   │         │          │         │
   └─────────┴────┬─────┴─────────┘
                   │
            ┌──────▼──────┐
            │ Local Store  │
            │  (SQLite)    │
            └─────────────┘
```

### 模块职责

- **Context Collector**：监听前台 App 切换、App 生命周期事件，写入本地数据库
- **System Monitor**：轮询系统级内存压力、per-process 资源占用
- **Workspace Matcher**：根据 Context Collector 的数据判断当前所处场景
- **Reclaim Scorer**：结合 System Monitor + Workspace Matcher 的输出，为每个进程计算分数
- **Action Executor**：执行用户确认（或按授权级别自动执行）的处理动作，且只做第 2 节范围内允许的事
- **Local Store**：SQLite，全部数据留在本地，无网络上传

---

## 4. 数据模型

### 4.1 Workspace（用户定义）

```swift
struct Workspace: Codable, Identifiable {
    let id: UUID
    var name: String                    // "Coding", "Entertainment"
    var coreAppBundleIDs: Set<String>    // 核心 App，几乎不参与打分降级
    var observedAppFrequency: [String: Double]
                                         // bundleID -> 历史共现频率，自动累积，不需要用户维护
    var createdAt: Date
    var lastActiveAt: Date
}
```

### 4.2 ProcessSnapshot（周期性采样，写入 SQLite）

```swift
struct ProcessSnapshot: Codable {
    let timestamp: Date
    let pid: Int32
    let bundleID: String?
    let processName: String
    let memoryFootprintMB: Double
    let cpuPercent: Double
    let isForeground: Bool
    let idleSeconds: TimeInterval        // 自行统计：距上次前台激活的时长
}
```

SQLite 表：`process_snapshots`，按 `timestamp` 建索引，保留策略见 8.4。

### 4.3 ReclaimScoreRecord

```swift
struct ReclaimScoreRecord: Codable {
    let bundleID: String
    let score: Double                    // 0-100，越高越"可处理"
    let components: ScoreComponents      // 分项，供 UI 展示可解释性
    let suggestedAction: SuggestedAction // .none / .throttle / .freeze / .quit
    let computedAt: Date
}

struct ScoreComponents: Codable {
    let idleContribution: Double
    let memorySizeContribution: Double
    let restartabilityContribution: Double
    let workspacePenalty: Double         // 在当前 workspace 内 → 大幅扣分（不建议处理）
    let foregroundPenalty: Double        // 前台 App → 极大扣分
}

enum SuggestedAction: String, Codable {
    case none, throttle, freeze, quit
}
```

### 4.4 UserFeedback（用于后续调权重，v1 只存不用）

```swift
struct UserFeedback: Codable {
    let bundleID: String
    let scoreAtDecisionTime: Double
    let userAction: String   // "accepted" / "rejected" / "manual_override"
    let timestamp: Date
}
```

---

## 5. 核心算法

### 5.1 Workspace 识别

采用滑动窗口 + **区分度证据**，纯规则、可解释、无需训练。不用 Jaccard：Jaccard 的分母包含场景核心 App 全集，办公场景常用软件一多、当场只用 WebStorm 等少数几个时分数会被压低；娱乐场景只有微信和 Chrome 时，开一个 Chrome 就能到 50%，真实办公会被判成娱乐。

```
active = 过去 N 分钟内曾处于前台的 App（按进程族收束到主应用，默认 N=10）
df(a)  = 有多少个场景把 a 列为核心 App
区分度(a) = 1 / df(a)          // 独有（如 WebStorm / IntelliJ）= 1.0；Chrome 若在两个场景 = 0.5
新近度(a) = 0.5 ^ (距上次前台的分钟数 / 8)

证据(W) = Σ_{a ∈ active ∩ W.core} 区分度(a) × 新近度(a)
          // 没用到的核心 App 不加也不减，办公清单长短不再参与计算

若当前已确认场景 sticky 的证据 > 0：
  仅当挑战者证据 > sticky + 0.3 且独有命中数 ≥ sticky 时才切走
  否则留在 sticky（短暂回微信不会把办公打成娱乐）

判定：
  若选中场景有独有 App 命中 → 采用该场景
  否则若证据 < 0.6，或领先第二名不足 0.35 → Unclassified
  只开 Chrome 这类共享 App → 未分类，不触发任何自动逻辑
```

### 5.2 Reclaim Score 公式

```
score = w1 × normalize(idleMinutes, cap=45)
      + w2 × normalize(memoryFootprintMB, cap=2048)
      + w3 × restartabilityBonus(bundleID)     // 查本地静态表，默认 0.5
      + w6 × (classified && !isInCurrentWorkspace ? 1.0 : 0)
      − w4 × (isInCurrentWorkspace ? 1.0 : 0)  // 大权重
      − w5 × (isForeground ? 1.0 : 0)          // 权重设为足以让 score 归零

初始权重（可在 Settings 调整；seed-user 校准后的值）：
w1 = 30, w2 = 25, w3 = 15, w4 = 80, w5 = 999
w6 = 28   // 已分类场景下，不在当前 workspace 的 App 加分，使切走后的浏览器能在数分钟内达到冻结，而不是卡在「降低优先级」
idleCapMinutes = 45
memoryCapMB = 2048

score 归一化到 0-100，clip 下界为 0。离场景加分在归一化之后加入，不进入 (w1+w2+w3) 分母。
```

分数区间 → 建议动作映射（v1 固定阈值，不做机器学习）：

```
score < 30           → .none
30 <= score < 60      → .throttle   （nice 或 SIGSTOP duty-cycle）
60 <= score < 85      → .freeze     （SIGSTOP，可 SIGCONT 恢复）
score >= 85           → .quit       （仅当 App 无未保存内容提示时才建议）
```

### 5.3 Action Executor

产品动作只有 **保留 / 降低优先级 / 退出**。`.freeze` 一律拒绝（`已停用冻结`）。启动时仍会 `SIGCONT` 旧版本留下的冻结进程。

- `.throttle`：`setpriority()` / `taskpolicy`，记下 `originalNice`，只还原自己改过的
- `.quit`：`NSRunningApplication.terminate()`，非 SIGKILL
- PID + 内核启动时间对不上视为 PID 复用，拒绝并丢掉本工具账本
- 不单独处理 Helper / Renderer

**重要**：降低优先级不回收内存。UI「预计可释放」只统计建议退出的占用，并标明是系统后续自然回收，不是本工具直接完成的。

### 5.4 授权级别与自动执行

决策者是 Jev，不是场景匹配，也不是本地分数阈值。

1. 采样系统负载（内存压力、CPU、内存占用）和正在运行的应用族
2. 本地划灰区：排除前台、保护进程、VPN/VM、会议/录屏、IM、输入法/辅助、常用、accessory、非用户 App
3. 把负载 + 灰区名单（最多 12 个，按内存）一次交给 Jev；每个 App 选择 `keep` / `throttle` / `quit`。不确定或失败 → 保留
4. **Level 0**：Jev 给出降级/退出后弹出独立确认窗口（不依赖菜单栏面板打开），用户确认才执行
5. **Level 1**：同一套决策自动执行（自动退出要求空闲至少约 30 秒），完成后发系统通知
6. **Level 2**：不可用，写入配置会回退到 Level 0

工作场景匹配、切场景冻结、分类表自动回收不再驱动动作。

灰区硬门（不进 Jev 名单）：前台、保护进程、VPN/VM、会议/录屏、IM、输入法/辅助、常用、菜单栏 accessory、非用户 App。有窗口可以进灰区。

### 5.6 进程族（Helper / Renderer）

Chrome、Edge、Brave、Electron 等应用会拆成主进程 + Helper / Renderer / GPU，它们有独立的 bundle ID（例如 `com.google.Chrome.helper.renderer`）。

这些子进程几乎不会成为 NSWorkspace 前台应用，若按 PID 独立打分，空闲时间会被算成「从进程启动至今」，从而被单独降低优先级或冻结。那会打断主进程与子进程的 IPC，表现为开链接失败、页面无响应等。

规则：

- 以 `.helper` 为界把 bundle ID 收束到主应用（`….helper.renderer` → 主应用）
- 再按 `NSRunningApplication` 主 PID、可执行文件是否在 `.app` 里、父 PID 树把没有特殊命名的子进程并进同一组
- 列表按进程族合并，Helper 不单独占一行
- 空闲、前台、场景归属继承主应用
- 禁止只对 Helper / Renderer 执行 throttle / freeze / quit；要对就对整个应用一起做
- 场景选择器不列出 Helper，避免用户把 Renderer 当成独立 App 加进场景
- 冻结 / 降速 / 退出前核对 PID 的内核启动时间；对不上视为 PID 复用，拒绝操作并清掉本工具自己的账本
- 只还原本工具改过的暂停和 nice 原值；不 SIGCONT 别人停掉的进程，不把 nice 抬回 0（除非原来就是 0）

Safari 的 `com.apple.WebKit.WebContent` 会被多个 App 共用，不并入 Safari，也不在本次范围内按族处理。

### 5.7 Jev 灰区回收（TypeSafe System One）

Jev 是决策模型，不是 agent：只返回 typed Choice，不发信号。代码保持控制流和硬门。

**一次请求**：state 含当前负载（压力、CPU、内存、前台 App）+ 灰区运行中 App 列表（空闲、占用、是否有窗）。每个 App 一个 Choice：`keep` / `throttle` / `quit`。冻结已停用，模型若仍返回 freeze，本地夹成 throttle。

**合成**：confidence < 0.7 → 保留；`quit` 且 confidence < 0.85 → 降为 throttle。失败、超时、pending → 全部保留。

**有窗口也可以问**；有窗不再是咨询禁令。退出走 `terminate()`。

---

## 6. 权限与系统 API 清单

| 功能 | API | 权限要求 | 备注 |
|---|---|---|---|
| Memory Pressure 事件 | `DispatchSource.makeMemoryPressureSource()` | 无 | 官方稳定 API |
| 前台 App 监听 | `NSWorkspace.didActivateApplicationNotification` | 无 | |
| 进程列表/资源占用 | `proc_pidinfo`, `proc_pid_rusage` | 无（同用户） | Apple 标注为 private，未来可能变化，需做兼容层 |
| 降优先级 | `setpriority()` | 无（同用户） | 标准 POSIX |
| 解冻旧残留 | `kill(pid, SIGCONT)` | 无（同用户） | 不再新发 SIGSTOP |
| 退出 App | `NSRunningApplication.terminate()` | 无 | 公开 API |
| Level 0 确认窗口 | `NSPanel` | 无 | 浮动独立窗口，不依赖菜单栏面板打开 |
| Level 1 系统通知 | `UNUserNotificationCenter` | 用户授权通知 | 横幅 + 通知中心；拒绝授权不影响自动执行 |

**分发方式**：不走 Mac App Store 沙盒（沙盒会限制向其他进程发信号），采用 Developer ID 签名 + Apple 公证（notarization）的 DMG 直接分发，与 App Tamer、CleanMyMac 路径一致。

---

## 7. UI/UX 要点

- 菜单栏图标：常态显示当前 Memory Pressure 简要状态（颜色编码：绿/黄/红）
- 点击展开面板：
  - 顶部：Pressure / RAM / Compressed / Swap、CPU/GPU
  - 列表：运行中应用族；建议来自 Jev（保留 / 降级 / 退出）
  - Level 0：Jev 给出降级/退出后弹出独立确认窗口；Level 1 自动执行并发系统通知
- 常用页：跨场景保活，不进灰区
- 设置页：授权级别、Jev Key/URL、采样间隔。Level 2 可见但不可选

---

## 8. 版本路线

### 8.1 当前
- 负载 + 灰区运行中 App 一次交给 Jev
- 动作：保留 / 降优先级 / 退出（无冻结）
- Level 0 独立窗口确认；Level 1 自动执行并发系统通知

### 8.2 已移除
- 工作场景匹配、切场景自动冻结、Markov 预测、安装应用分类泵

### 8.3 v2.5
- 关联规则挖掘（类 Apriori），捕捉"打开 A 后大概率短时间内打开 B"的模式
- 预热逻辑：预测到即将需要的 App，避免误伤

### 8.4 v3（视 v1/v2 反馈决定是否做）
- 完全自动模式（授权 Level 2），默认关闭
- 数据留存策略：`process_snapshots` 超过 14 天的原始记录做聚合汇总（每小时均值），不无限增长

---

## 9. 技术栈

- **语言/框架**：Swift + SwiftUI（菜单栏 App 用 `MenuBarExtra` 或 `NSStatusItem`）
- **本地存储**：SQLite（建议用 GRDB.swift，成熟的 Swift SQLite 封装）
- **最低系统版本**：macOS 13（对齐 Memory Pressure API 与目标用户的 Intel + Apple Silicon 兼容需求）
- **签名/分发**：Developer ID + Notarization，DMG 分发，Sparkle 做自动更新

---

## 10. 风险与已知限制

1. `proc_pidinfo` 系接口是 Apple 标注的 private interface，macOS 大版本升级时行为可能变化，需要每年跟进系统更新验证
2. Action Executor 的 `.freeze`/`.quit` 效果依赖目标 App 是否规范处理 SIGSTOP/未保存状态提示，个别 App 可能有异常表现，需要建立"问题 App 黑名单"机制（用户反馈后拉黑，不再对其建议自动处理）。对有窗口的 AppKit 应用执行 `SIGSTOP` 会卡住 WindowServer（已在 5.4 禁止）
3. Reclaim Score 的固定权重是经验值，v1 阶段没有真实用户反馈数据支撑，预期需要至少一轮种子用户使用后调整
4. 内存相关的"预计可释放"数值本质是估算，不承诺实际效果，需要在首次使用时做一次性说明（onboarding），避免后续被认为是虚假宣传
