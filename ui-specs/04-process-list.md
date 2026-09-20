# 04. 进程治理面板 (Process List Tab)

## 进程治理面板
- 用户称呼：进程 Tab、进程列表、应用治理面板、Process List
- 入口：主面板底部导航栏 → 点击第 1 个 Tab “进程”（默认选中项）
- 关键选择器：`button "进程" of window 1`；搜索框: `text field 1` (Placeholder=`"搜索应用或进程..."`)；开关: `checkbox "只看建议"` (AXRole=`AXCheckBox`)；操作按钮: `button "降优先级"`, `button "退出"`, `button "恢复优先级"`, `button "恢复"`；行内评分胶囊: `AXStaticText` (0-100)；折叠展开触发: 行单击事件；次级动作: `button "设为常用"` / `button "取消常用"`, `button "不再建议"`
- 子功能：运行中应用与进程实时列表浏览、应用名/PID/Bundle ID 模糊搜索、“只看建议”一键过滤白名单与前台、进程族与 Helper 自动并组、展开查看多维度评分明细与进程拓扑树、降低/恢复调度优先级（nice/taskpolicy）、请求应用优雅退出、常用加白与加入黑名单
- 前置条件：系统有正在运行的用户级进程；SystemMonitor 周期性更新正常
- 常见故障现象：列表显示“当前没有建议降级或退出的应用” → 开启了“只看建议”，当前运行应用全部处于前台或常用保护中，关掉开关即可查看全量；操作按钮置灰不可点击 → 该应用当前处于前台活跃状态

---

### 可见控件与属性字典

#### 1. 顶部控制栏

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互事件 |
|---|---|---|---|---|---|
| 状态/异常横幅 | `HStack` (带警告图标) | `AXGroup` | 条件呈现 (`coordinator.lastMessage != nil`) | 错误或通知文本（红字或灰字） | 展示操作结果或错误反馈 |
| 历史冻结告警区 | `VStack` (带恢复按钮) | `AXGroup` | 条件呈现 (`!coordinator.frozen.isEmpty`) | `"旧版本留下的冻结进程"` + 逐项 `"恢复"` 按钮 | 点击解冻旧版本遗留 SIGSTOP |
| 搜索输入框 | `TextField` | `AXTextField` | `text field 1 whose placeholder is "搜索应用或进程..."` | 占位符 `"搜索应用或进程..."` | 键入文本过滤进程列表 |
| 清除搜索按钮 | `Button` (Image: `xmark.circle.fill`) | `AXButton` | 搜索框内部尾部按钮 | 清除图标 | 点击清空当前搜索文本 |
| 只看建议开关 | `Toggle` (.switch, .mini) | `AXCheckBox` / `AXSwitch` | `checkbox "只看建议"` | 标签 `"只看建议"` | 切换过滤模式（全量 vs 仅高分建议） |

#### 2. 进程行卡片 (ProcessGroupRow - 收起态)

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互事件 |
|---|---|---|---|---|---|
| 应用图标 | `AppIconView` | `AXImage` | 行首图标 (28x28 pt) | 原生 .app 图标或系统 fallback | 展示应用外观 |
| 应用显示名称 | `Text(group.displayName)` | `AXStaticText` | 应用主标题 | 如 `"Google Chrome"`, `"Xcode"` | 展示应用名 |
| 状态徽标 | `Text` (Capsule 标签) | `AXStaticText` | 名称右侧胶囊 | `"前台"` (绿) / `"常驻"` (紫) / `"常用"` (紫) / `"<N> 进程 · Helper"` (灰) | 状态标识 |
| 资源指标行 | `HStack` | `AXStaticText` | 第二行副标题 | 内存 `X MB` · `CPU X%` · 闲置时长 `Xm` | 核心资源监控指标 |
| 主要操作按钮 | `Button` (.borderedProminent) | `AXButton` | 操作列按钮 | `"降优先级"` / `"退出"` / `"恢复"` / `"恢复优先级"` | 触发治理或恢复动作 |
| 状态胶囊 (无操作时) | `Text(statusTitle)` | `AXStaticText` | 操作列静态标签 | `"已降级"` / `"已冻结"` / `"正常"` | 状态标识 |
| 综合评分胶囊 | `Text(group.score)` | `AXStaticText` | 行尾数字 (0-100) | 分数越低越安全，越高越建议回收 (随分数变色) | 评估参考 |
| 行卡片主体 | `VStack` | `AXGroup` | 整个行区域 | 背景带悬停 hover 渐变 | 单击触发展开/折叠明细 |

#### 3. 展开详情卡片 (ProcessGroupRow - 展开态)

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互说明 |
|---|---|---|---|---|---|
| 评分明细条目 | `ScoreBreakdownView` | `AXGroup` | 展开区顶部 | 展示各打分项条状图：CPU、内存、空闲时长、前台惩罚、常用惩罚等 | 透析算法得分根据 |
| 进程拓扑树 | `ForEach(group.members)` | `AXGroup` | 树状缩进列表 | 展示主进程及关联 Helper/Renderer 的 PID、内存及角色标签（如 `Renderer`, `GPU`） | 了解应用进程拓扑 |
| 备选动作按钮组 | `ForEach(alternateActions)` | `AXButton` | 底部动作栏左侧 | `"降优先级"`, `"退出"`, `"冻结"` | 允许用户自主选择备选动作 |
| 常用切换按钮 | `Button` | `AXButton` | `button "设为常用"` / `button "取消常用"` | `"设为常用"` 或 `"取消常用"` | 加入或移除保活白名单 |
| 不再建议按钮 | `Button("不再建议")` | `AXButton` | `button "不再建议"` | `"不再建议"` | 将应用移入黑名单不再产生打分建议 |

---

### 自动化测试代码参考

```applescript
-- AppleScript: 搜索进程并单击展开第一项
tell application "System Events"
    tell process "ResourceSteward"
        tell window 1
            -- 在搜索框输入关键词
            set value of text field 1 to "Chrome"
            delay 0.5
            -- 单击列表中的第一个卡片组以展开详情
            click group 1 of scroll area 1
        end tell
    end tell
end tell
```

```swift
// XCUITest
let app = XCUIApplication(bundleIdentifier: "cc.resourcesteward")
let window = app.windows.firstMatch

// 搜索应用
let searchField = window.textFields["搜索应用或进程..."]
searchField.click()
searchField.typeText("Code\n")

// 切换只看建议
let filterToggle = window.checkBoxes["只看建议"]
filterToggle.click()
```
