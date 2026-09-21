# ResourceSteward (资源管家) 页面与功能全景规格清单 (UI Inventory)

本目录记录 **ResourceSteward (macOS 上下文感知资源管家)** 应用程序的全部页面、功能模块、入口路径、可见控件与选择器规范，供自动化测试（XCUITest / Accessibility / UI Automation）、QA 验收及产品文档使用。

---

## 页面与功能架构图 (Navigation Flow)

```mermaid
flowchart TD
    OS[macOS 系统菜单栏] -->|左键单击| StatusItem["01. 菜单栏状态指示器 (Status Bar Item)"]
    
    StatusItem -->|未完成引导| Onboarding["02. 新手引导页 (Onboarding View)"]
    StatusItem -->|已完成引导| MainPanel["03. 主看板与面板外壳 (Dashboard & Shell)"]
    
    Onboarding -->|点击'我明白了'| MainPanel
    
    MainPanel -->|Tab 1 (默认)| ProcessList["04. 进程治理面板 (Process List Tab)"]
    MainPanel -->|Tab 2| Favorites["05. 常用保活管理 (Favorite Apps Tab)"]
    MainPanel -->|Tab 3| Settings["06. 设置与 Jev AI (Settings Tab)"]
    
    ProcessList -->|点击行展开| DetailView["进程拓扑树与评分透视"]
    ProcessList -->|触发治理 (Level 0)| ConfirmPanel["07. 浮动确认弹窗 (Confirm Prompt Panel)"]
    
    Settings -->|切换授权 Level 1| AutoReclaim["08. 系统通知与后台调度 (Reclaim Notifier)"]
    AutoReclaim -->|高负载后台处理完成| NotificationBanner["macOS 系统通知横幅"]
```

---

## 功能清单汇总 (统一规格初稿)

## 菜单栏状态指示器
- 用户称呼：菜单栏图标、状态栏图标、常驻托盘图标、Status Bar Item
- 入口：macOS 顶部系统菜单栏（Menu Bar 2 托盘区）；点击展开主面板
- 关键选择器：`menu bar item 1 of menu bar 2 of application "ResourceSteward"`；AXRole=`AXMenuBarItem`；AXTitle=`"memorychip"`；XCUITest: `app.statusItems.firstMatch`
- 子功能：单体菜单栏图标展示、单击唤起或收起主面板
- 前置条件：应用已启动并常驻后台（`ResourceSteward.app` 正在运行）
- 常见故障现象：图标未在顶栏出现 → 刘海屏遮挡或右侧托盘图标过多被系统折叠，需借助 Bartender/Ice 查看；点击无反应 → 应用主事件循环阻塞

## 新手引导页
- 用户称呼：Onboarding 面板、新手引导、首次使用声明页、规则声明页
- 入口：应用安装或清空数据后首次启动，点击菜单栏图标（`settings.hasCompletedOnboarding == false`）
- 关键选择器：`window 1 of application "ResourceSteward"`；AXTitle=`"资源管家"`；主要按钮: `button "我明白了"` (`app.buttons["我明白了"]`)；声明卡片容器: `OnboardPoint`
- 子功能：明确产品 Non-Goals 能力边界（不承诺直接压缩内存）、四条核心交互原则展示、一键确认并持久化进入主界面
- 前置条件：本地 SQLite 数据库中 `hasCompletedOnboarding` 为 `false`
- 常见故障现象：点击“我明白了”无响应或无法切入主面板 → 本地 SQLite 写入受阻或 store 未能持久化；每次启动均重复出现引导 → 数据库 fallback 到 NSTemporaryDirectory

## 资源看板与面板外壳
- 用户称呼：主面板、Dashboard、看板概览、主窗口顶底栏
- 入口：点击菜单栏图标（引导已完成状态下唤起）
- 关键选择器：`window 1 of application "ResourceSteward"` (subrole=`AXSystemDialog`)；模式标识: `AXStaticText "半自动"` / `AXStaticText "仅建议"`；Tab 导航: `button "进程"`, `button "常用"`, `button "设置"`；刷新按钮: `button` with AXHelp `"立即刷新"`；退出按钮: `button` with AXHelp `"退出管家（会自动解冻）"`
- 子功能：环形 RAM 表盘占用率展示、CPU/GPU/内存多维硬件指标柱状图、后台闲置应用释放估算与治理状态胶囊、三大功能 Tab 切换、一键强制立即刷新、安全退出应用（自动解冻受控进程）
- 前置条件：已完成新手引导（`hasCompletedOnboarding == true`）
- 常见故障现象：点击面板外部面板立即消失 → macOS 窗口式 MenuBarExtra 失去焦点默认自动关闭；GPU 数据显示破折号或“当前无法读取” → 系统无独立 GPU 或无 IOKit/Metal 读取权限

## 进程治理面板
- 用户称呼：进程 Tab、进程列表、应用治理面板、Process List
- 入口：主面板底部导航栏 → 点击第 1 个 Tab “进程”（默认选中项）
- 关键选择器：`button "进程" of window 1`；搜索框: `text field 1` (Placeholder=`"搜索应用或进程..."`)；开关: `checkbox "只看建议"` (AXRole=`AXCheckBox`)；排序维度按钮: `button "默认 排序"`, `button "CPU 排序"`, `button "GPU 排序"`, `button "内存 排序"`；排序顺序切换: `button "切换排序顺序，当前降序"` / `button "切换排序顺序，当前升序"`；操作按钮: `button "降优先级"`, `button "退出"`, `button "恢复优先级"`, `button "恢复"`；行内评分胶囊: `AXStaticText` (0-100)；折叠展开触发: 行单击事件；次级动作: `button "设为常用"` / `button "取消常用"`, `button "不再建议"`
- 子功能：运行中应用与进程实时列表浏览、应用名/PID/Bundle ID 模糊搜索、“只看建议”一键过滤白名单与前台、多维度排序（默认综合评分、CPU占用率、GPU占用率、内存占用率，支持升序/降序切换）、进程族与 Helper 自动并组、展开查看多维度评分明细与进程拓扑树、降低/恢复调度优先级（nice/taskpolicy）、请求应用优雅退出、常用加白与加入黑名单
- 前置条件：系统有正在运行的用户级进程；SystemMonitor 周期性更新正常
- 常见故障现象：列表显示“当前没有建议降级或退出的应用” → 开启了“只看建议”，当前运行应用全部处于前台或常用保护中，关掉开关即可查看全量；操作按钮置灰不可点击 → 该应用当前处于前台活跃状态

## 常用保活管理面板
- 用户称呼：常用 Tab、保活白名单、常用应用管理、Favorite Apps
- 入口：主面板底部导航栏 → 点击第 2 个 Tab “常用”
- 关键选择器：`button "常用" of window 1`；说明胶囊: `AXStaticText "全场景常驻保活 · VPN 与 Docker 已默认免打扰"`；保活栏数量: `AXStaticText "(N)"`；保活应用胶囊: `button` with AXHelp `"移除保活"`；筛选框: `text field 1` (Placeholder=`"快速筛选..."`)；应用项复选框: `checkbox` (AXRole=`AXCheckBox`)
- 子功能：全场景常驻白名单说明展示、当前已保活应用横向滚动胶囊、一键点击“x”移除保活、运行中第三方应用扫描与快速搜索、勾选/取消勾选切换保活状态、系统内置常驻策略提示（显示“系统常驻”标签且禁止取消）
- 前置条件：系统存在正在运行且带有有效 Bundle ID 的第三方应用
- 常见故障现象：列表提示“没有检测到带 Bundle ID 的第三方应用” → 系统中只运行纯 CLI 脚本或守护进程；Docker / VPN 应用无法取消勾选 → 属于系统内置硬编码免打扰名单，无法被用户移除

## 设置与 Jev AI 配置面板
- 用户称呼：设置 Tab、配置中心、Jev 配置、Settings
- 入口：主面板底部导航栏 → 点击第 3 个 Tab “设置”
- 关键选择器：`button "设置" of window 1`；授权单选按钮: `button` containing `"仅建议 (Level 0)"` / `button` containing `"半自动 (Level 1)"`；滑块: `slider 1` (AXRole=`AXSlider`, 范围 2-10s)；Jev 开关: `checkbox "启用 Jev 灰区判断"`；预设按钮: `button "TypeSafe"`, `button "OpenRouter"`；输入框: `text field "Base URL"`, `text field "模型"`, `secure text field "API Key"`；操作按钮: `button "保存 Key"`, `button "清除 Key"`；存储路径: `AXStaticText` (SQLite 路径)
- 子功能：授权模式切换（Level 0 手动弹窗确认 vs Level 1 自动执行通知）、采样间隔微调滑块（2s ~ 10s）、Jev 大模型灰区决策总开关、供应商一键预设套用（TypeSafe / OpenRouter）、自定义 API 端点与模型名称、API Key 存取至本地 SQLite（支持保存与清除）、本地 SQLite 存储文件物理路径展示与复制
- 前置条件：本地 SQLite 可读写；网络可访问对应大模型 API 端点
- 常见故障现象：保存 API Key 报错 → SQLite 写入失败或文件不可写；Jev 建议不出现 → Jev 开关未打开、API Key 未配置或网络不通时保留

## 浮动确认弹窗
- 用户称呼：确认弹窗、处理确认窗口、Jev 决策确认框、Confirm Dialog
- 入口：Level 0 模式下触发治理动作，或 Jev 批量决策建议生成时，系统居中弹出独立浮动窗口
- 关键选择器：`window "确认建议" of application "ResourceSteward"` (subrole=`AXStandardWindow`, 宽 380 pt，高度随内容调整)；单项标题: `AXStaticText` (`pending.action.confirmationTitle`)；批量标题: `AXStaticText "Jev 建议处理此应用"`；取消按钮: `button "取消"` / `button "暂不处理"` (快捷键: `Escape`)；执行按钮: `button "确认执行"` (快捷键: `Return`，退出动作为红色高亮)
- 子功能：单应用处理二次确认与破坏性动作安全警告、Jev 单项建议与负载、观测及判断展示、Helper 与主应用联动说明、全键盘快捷键支持（Esc 取消 / Enter 确认）、窗口关闭拦截（防止状态锁死）
- 前置条件：系统处于 Level 0（仅建议）模式，存在待处理的单项操作或 Jev 批次决策
- 常见故障现象：按快捷键没反应 → 弹窗失去焦点，点击弹窗重新激活即可；点击“确认执行”后目标应用没反应 → 目标应用已在前台被激活或用户正在编辑，安全熔断机制生效

## 系统通知与后台自动回收
- 用户称呼：系统通知、后台调度、自动回收提示、Auto Reclaim
- 入口：设置中开启 Level 1（半自动）；系统负载达到阈值且存在满足治理条件的后台应用时，后台自动触发
- 关键选择器：通知请求标识: `cc.resourcesteward.auto-reclaim.<UUID>`；通知分类: `UNNotificationRequest`；通知标题: `notice.title`（如 `"已自动调整应用资源"`）；通知内容: `notice.body`（如 `"已降低后台应用 Xcode 的优先级"`）；系统通知横幅: `NotificationCenter`
- 子功能：后台静默执行资源回收（限制为降优先级或退出，无冻结）、治理完成后发送系统横幅通知附带提示音、通知中心历史记录归档、系统进程/常驻白名单严格防误触
- 前置条件：设置中开启 Level 1；已授予 ResourceSteward 系统通知权限
- 常见故障现象：执行了治理但未收到通知 → 系统通知权限未授权，或系统开启了“勿扰模式 / 专注模式”；目标应用未被自动处理 → 命中 90 秒动作冷却或窗口保护策略

---

## 详细规格子文档索引

每个页面的完整控件字典、状态迁移图和选择器定位详情，可参阅下列单独子文档：

1. [01. 菜单栏状态指示器 (Status Bar Item)](file:///Users/cengsin/agent-projects/ContextAwareResourceManager/ui-specs/01-status-bar-item.md)
2. [02. 新手引导页 (Onboarding View)](file:///Users/cengsin/agent-projects/ContextAwareResourceManager/ui-specs/02-onboarding-view.md)
3. [03. 资源看板与面板外壳 (Dashboard & Shell)](file:///Users/cengsin/agent-projects/ContextAwareResourceManager/ui-specs/03-dashboard-header.md)
4. [04. 进程治理面板 (Process List Tab)](file:///Users/cengsin/agent-projects/ContextAwareResourceManager/ui-specs/04-process-list.md)
5. [05. 常用保活管理面板 (Favorite Apps Tab)](file:///Users/cengsin/agent-projects/ContextAwareResourceManager/ui-specs/05-favorite-apps.md)
6. [06. 设置与 Jev AI 配置面板 (Settings Tab)](file:///Users/cengsin/agent-projects/ContextAwareResourceManager/ui-specs/06-settings-view.md)
7. [07. 浮动确认弹窗 (Confirm Prompt Panel)](file:///Users/cengsin/agent-projects/ContextAwareResourceManager/ui-specs/07-confirm-panel.md)
8. [08. 系统通知与后台自动调度 (Reclaim Notifier)](file:///Users/cengsin/agent-projects/ContextAwareResourceManager/ui-specs/08-notifications.md)

## Feature 文档

- [JevDecisionPipeline：候选筛选、两阶段判断与授权执行](JevDecisionPipeline/README.md)

### Feature 开发流程

1. 使用稳定的 PascalCase feature 名称；新功能专属文件保存在 `Sources/<Target>/Features/<FeatureName>/`，检查保存在 `Sources/StewardChecks/Features/<FeatureName>/`，跨 target 同名。
2. 开发新功能时同步创建 `ui-specs/<FeatureName>/README.md`，并更新本索引及关联页面文档。
3. 文档包含入口、可见控件、选择器、行为规则、错误处理和验证方式；共享入口只接线，功能实现按职责拆文件。
4. 执行构建、对应行为检查、注释检查；文档始终反映当前实现。
