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
| 降低某进程 CPU 占用 | ✅ | `setpriority()` 或 `SIGSTOP/SIGCONT` |
| 冻结/恢复某进程 | ✅ | `SIGSTOP/SIGCONT`，同用户进程无需 root |
| 退出某进程 | ✅ | `NSRunningApplication.terminate()` |
| **直接压缩/回收其他进程的内存页** | ❌ 永久不可行 | 无公开 API，需要 kernel VM subsystem 权限 |
| **获取其他进程 task port 并 suspend/resume 内存态** | ❌ 永久不可行 | 受 SIP + entitlement 限制 |
| 读取其他 App 的窗口内容/剪贴板等敏感信息 | ❌ 不在范围内 | 隐私边界，非技术限制 |

**UI 文案硬性要求**：任何"优化内存"相关的按钮/提示，其实际动作必须是"退出"或"冻结"，不能出现"压缩中""正在释放内存"等暗示直接内存回收的措辞。

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
score = w1 × normalize(idleMinutes, cap=120)
      + w2 × normalize(memoryFootprintMB, cap=8192)
      + w3 × restartabilityBonus(bundleID)     // 查本地静态表，默认 0.5
      − w4 × (isInCurrentWorkspace ? 1.0 : 0)  // 大权重
      − w5 × (isForeground ? 1.0 : 0)          // 权重设为足以让 score 归零

初始权重（可在 Settings 调整）：
w1 = 30, w2 = 25, w3 = 15, w4 = 80, w5 = 999

score 归一化到 0-100，clip 下界为 0
```

分数区间 → 建议动作映射（v1 固定阈值，不做机器学习）：

```
score < 30           → .none
30 <= score < 60      → .throttle   （nice 或 SIGSTOP duty-cycle）
60 <= score < 85      → .freeze     （SIGSTOP，可 SIGCONT 恢复）
score >= 85           → .quit       （仅当 App 无未保存内容提示时才建议）
```

### 5.3 Action Executor 的诚实降级

```swift
func execute(action: SuggestedAction, pid: pid_t) {
    switch action {
    case .throttle:
        setpriority(PRIO_PROCESS, UInt32(pid), 15) // nice 值提高，降低调度优先级
    case .freeze:
        kill(pid, SIGSTOP)
        // 记录 pid，供用户手动或场景切换时 SIGCONT 恢复
    case .quit:
        // 走 NSRunningApplication.terminate()，非 SIGKILL，
        // 给 App 机会弹出"未保存"提示
    case .none:
        break
    }
}
```

**重要**：`.freeze` 和 `.quit` 都不产生"内存被回收"的直接效果，UI 展示的"预计可释放"数值应标注为"预计"，并说明是系统后续自然回收的结果，不是本工具直接完成的。

### 5.4 场景切换半自动（v2，授权 Level 1）

触发条件（全部满足才自动处理）：

1. 授权级别为 Level 1（`sceneSwitch`）
2. 当前场景是已分类 workspace（未分类不触发任何自动处理，与 5.1 一致）
3. 已确认的场景 ID 发生变化（启动后第一次匹配只采纳当前场景，不视为切换）
4. 新场景连续保持默认 15 秒，避免证据分在阈值附近抖动

处理范围：

- **过滤器**：只处理 Reclaim Score 已给出建议（`suggestedAction != .none`）的离场景应用。刚在前台、分数不够的应用不会被盲冻。
- **离场景**：不在新场景 `coreAppBundleIDs` 中、非前台、非保护、非黑名单。
- **常驻网络**：VPN / 代理 / Packet Tunnel（Shadowrocket、Clash、Surge、WireGuard、Tailscale 等）视为 Keep-Alive，分数归零，半自动与手动都不冻结。菜单栏 accessory 应用也不会被半自动处理。
- **常驻计算**：容器 / 虚拟机运行时（OrbStack 含 `vmgr`、Docker Desktop、Colima、Podman、UTM 等）同样 Keep-Alive。冻结它们会暂停 Linux VM，MySQL 等容器写入会失败。OrbStack 的 `dev.kdrag0n.MacVirt.vmgr` 并入主应用族，不单独打分。
- **用户常用**：用户可在「常用」页勾选任意 App（跨场景保活）。分数归零，半自动与手动都不冻结；Helper 随主应用一起保护。与场景核心 App 不同：常用不依赖当前 workspace。
- **半自动范围**：Level 1 只处理带 reverse-DNS bundle ID 的 App；`python` / `fontd` 这类进程名不会被切场景自动降级。
- **动作降级**：Level 1 将 `.quit` 改成 `.freeze`，避免未保存窗口被自动关掉。`.throttle` / `.freeze` 按建议执行。
- **恢复**：属于新场景核心 App 的已冻结进程会被 `SIGCONT` 恢复。用户从 Dock / Spotlight / Cmd-Tab 打开某个已冻结 App 时，按进程族解冻（含 Helper），不需要再到管家里点「恢复」。
- **Level 0**：仍记录切换（见 5.5），但不自动执行。
- **Level 2**：v3 才开放；当前若被写入配置会回退到 Level 0。

### 5.5 Markov 转移矩阵（v2）

每次**确认后的**场景切换写入 `workspace_transitions`：`from_id`、`to_id`（空字符串表示未分类）、`hour`（0–23）、`weekday`（1–7）、`timestamp`。`from == to` 不记。原始记录保留 180 天。

预测 `P(to | from, t)`：

1. 优先用同一小时的样本；样本数 < 3 则回退到同一时段（夜 0–5 / 上午 6–11 / 下午 12–17 / 晚上 18–23）
2. 仍不足则回退到该 `from` 的全天样本
3. Laplace 平滑 α = 1；候选集 = 用户定义的其他场景 + 未分类（当 `from` 已分类时）

v2 **只记录和展示**，不改变 Reclaim Score，也不用预测结果阻止或预热自动处理（那是 v2.5）。

### 5.6 进程族（Helper / Renderer）

Chrome、Edge、Brave、Electron 等应用会拆成主进程 + Helper / Renderer / GPU，它们有独立的 bundle ID（例如 `com.google.Chrome.helper.renderer`）。

这些子进程几乎不会成为 NSWorkspace 前台应用，若按 PID 独立打分，空闲时间会被算成「从进程启动至今」，从而被单独降低优先级或冻结。那会打断主进程与子进程的 IPC，表现为开链接失败、页面无响应等。

规则：

- 以 `.helper` 为界把 bundle ID 收束到主应用（`….helper.renderer` → 主应用）
- 列表按进程族合并，Helper 不单独占一行
- 空闲、前台、场景归属继承主应用
- 禁止只对 Helper / Renderer 执行 throttle / freeze / quit；要对就对整个应用一起做
- 场景选择器不列出 Helper，避免用户把 Renderer 当成独立 App 加进场景

Safari 的 `com.apple.WebKit.WebContent` 会被多个 App 共用，不并入 Safari，也不在本次范围内按族处理。

---

## 6. 权限与系统 API 清单

| 功能 | API | 权限要求 | 备注 |
|---|---|---|---|
| Memory Pressure 事件 | `DispatchSource.makeMemoryPressureSource()` | 无 | 官方稳定 API |
| 前台 App 监听 | `NSWorkspace.didActivateApplicationNotification` | 无 | |
| 进程列表/资源占用 | `proc_pidinfo`, `proc_pid_rusage` | 无（同用户） | Apple 标注为 private，未来可能变化，需做兼容层 |
| 降优先级 | `setpriority()` | 无（同用户） | 标准 POSIX |
| 冻结/恢复 | `kill(pid, SIGSTOP/SIGCONT)` | 无（同用户） | 沙盒环境下可能受限 |
| 退出 App | `NSRunningApplication.terminate()` | 无 | 公开 API |

**分发方式**：不走 Mac App Store 沙盒（沙盒会限制向其他进程发信号），采用 Developer ID 签名 + Apple 公证（notarization）的 DMG 直接分发，与 App Tamer、CleanMyMac 路径一致。

---

## 7. UI/UX 要点

- 菜单栏图标：常态显示当前 Memory Pressure 简要状态（颜色编码：绿/黄/红）
- 点击展开面板：
  - 顶部：Pressure / RAM / Compressed / Swap 数值
  - 列表：Top 进程，展示 score 及其分项（悬浮或点击展开，不是默认全展开）
  - 每项旁提供"应用建议"按钮（v1 默认不自动执行）
- Workspace 管理页：用户手动创建/编辑 workspace，选择 core apps（从当前运行进程里勾选；办公场景典型是 JetBrains IDE + 终端，不必把一次用不到的软件都打开才能被识别）
- 设置页：授权级别开关。v2 开放 Level 0 / Level 1；Level 2 可见但不可选
- 场景页：展示当前时段「接下来最常切到」的预测（样本不足时说明原因）

---

## 8. 版本路线

### 8.1 v1（本文档范围）
- Context Collector + System Monitor + Reclaim Scorer + Action Executor（手动确认）
- Workspace 用户手动定义，规则匹配识别当前场景
- 授权 Level 0：仅建议，用户点击执行

### 8.2 v2（本节已实现）
- Workspace 切换触发的半自动处理（授权 Level 1：切场景稳定后自动处理离场景 App，quit 降级为 freeze）
- Markov 转移矩阵记录 workspace 切换概率（按小时 / 时段 / 全天回退），仅展示不驱动打分

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
2. Action Executor 的 `.freeze`/`.quit` 效果依赖目标 App 是否规范处理 SIGSTOP/未保存状态提示，个别 App 可能有异常表现，需要建立"问题 App 黑名单"机制（用户反馈后拉黑，不再对其建议自动处理）
3. Reclaim Score 的固定权重是经验值，v1 阶段没有真实用户反馈数据支撑，预期需要至少一轮种子用户使用后调整
4. 内存相关的"预计可释放"数值本质是估算，不承诺实际效果，需要在首次使用时做一次性说明（onboarding），避免后续被认为是虚假宣传
