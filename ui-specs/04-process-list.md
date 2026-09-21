# 04. 进程治理面板 (Process List Tab)

## 进程治理面板
- 用户称呼：进程 Tab、进程列表、应用治理面板、Process List
- 入口：主面板底部导航栏 → 点击第 1 个 Tab “进程”（默认选中项）
- 关键选择器：`button "进程" of window 1`；搜索框: `text field 1` (Placeholder=`"搜索应用或进程..."`)；开关: `checkbox "只看建议"` (AXRole=`AXCheckBox`)；排序维度按钮: `button "默认 排序"`, `button "CPU 排序"`, `button "GPU 排序"`, `button "内存 排序"`；排序顺序切换: `button "切换排序顺序，当前降序"` / `button "切换排序顺序，当前升序"`；操作按钮: `button "降优先级"`, `button "退出"`, `button "恢复优先级"`, `button "恢复"`；行内评分胶囊: `AXStaticText` (0-100)；折叠展开触发: 行单击事件；次级动作: `button "设为常用"` / `button "取消常用"`, `button "不再建议"`
- 子功能：运行中应用与进程实时列表浏览、应用名/PID/Bundle ID 模糊搜索、“只看建议”一键过滤白名单与前台、多维度排序（默认综合评分、CPU占用率、GPU占用率、内存占用率，支持升序/降序切换）、进程族与 Helper 自动并组、展开查看多维度评分明细与进程拓扑树、降低/恢复调度优先级（nice/taskpolicy）、请求应用优雅退出、常用加白与加入黑名单
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
| 排序维度切换 | `Button` (默认/CPU/GPU/内存) | `AXButton` | `button "<维度> 排序"` | `"默认"`, `"CPU"`, `"GPU"`, `"内存"`，选中项附带箭头指示符 | 单击切换排序指标；再次点击当前指标反转升/降序 |
| 排序方向切换 | `Button` (降序/升序) | `AXButton` | `button "切换排序顺序，当前<顺序>"` | `"↓ 降序"` 或 `"↑ 升序"` | 单击在升序与降序之间反转排序 |

#### 2. 进程行卡片 (ProcessGroupRow - 收起态)

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互事件 |
|---|---|---|---|---|---|
| 应用图标 | `AppIconView` | `AXImage` | 行首图标 (28x28 pt) | 原生 .app 图标或系统 fallback | 展示应用外观 |
| 应用显示名称 | `Text(group.displayName)` | `AXStaticText` | 应用主标题 | 如 `"Google Chrome"`, `"Xcode"` | 展示应用名 |
| 状态徽标 | `Text` (Capsule 标签) | `AXStaticText` | 名称右侧胶囊 | `"前台"` (绿) / `"常驻"` (紫) / `"常用"` (紫) / `"<N> 进程 · Helper"` (灰) | 状态标识 |
| 资源指标行 | `HStack` | `AXStaticText` | 第二行副标题 | 内存 `X MB` · `CPU X%` · `GPU X%` · 闲置时长 `Xm` | 核心资源监控指标 |
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


### 采样计算与缓存

- 内置保活与类别规则按完整的 Bundle ID、进程名和路径缓存，每种规则最多保存 2,048 条结果；身份字段变化会重新计算，达到上限时清空后重新填充。
- 缓存仅覆盖静态规则。用户常用白名单、前台状态、PID 身份及执行前安全校验使用当前状态。
- 分组每轮建立不区分大小写的 Bundle ID、应用族、可执行路径和应用目录索引；路径归属匹配与身份匹配冲突时仍按运行应用提示的原始顺序选取，父子进程归并规则保持一致。
- 性能回归入口：`swift run -c release StewardChecks --benchmark`，固定 512 个进程、80 个应用提示，分别报告打分、分组、应用列表合并的首轮与中位耗时。该入口只运行合成数据计算，不执行进程治理。

#### 2026-09-21 性能回归记录

同机 Release 合成基准（512 个进程、80 个应用提示，每项 7 轮，中位数）：

| 计算路径 | 优化前 | 优化后 |
|---|---:|---:|
| 打分 | 277.184 ms | 35.994 ms |
| 进程分组 | 157.363 ms | 19.926 ms |
| 运行应用列表合并 | 108.866 ms | 7.036 ms |

前后结果校验值均为 `282303`。首轮打分为 84.749 ms，缓存热身后的收益更大。以上仅反映固定输入的计算开销，不代表整机 CPU、界面渲染或持久化开销的同比变化。
