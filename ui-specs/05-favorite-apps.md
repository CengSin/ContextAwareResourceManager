# 05. 常用保活管理面板 (Favorite Apps Tab)

## 常用保活管理面板
- 用户称呼：常用 Tab、保活白名单、常用应用管理、Favorite Apps
- 入口：主面板底部导航栏 → 点击第 2 个 Tab “常用”
- 关键选择器：`button "常用" of window 1`；说明胶囊: `AXStaticText "全场景常驻保活 · VPN 与 Docker 已默认免打扰"`；保活栏数量: `AXStaticText "(N)"`；保活应用胶囊: `button` with AXHelp `"移除保活"`；筛选框: `text field 1` (Placeholder=`"快速筛选..."`)；应用项复选框: `checkbox` (AXRole=`AXCheckBox`)
- 子功能：全场景常驻白名单说明展示、当前已保活应用横向滚动胶囊、一键点击“x”移除保活、运行中第三方应用扫描与快速搜索、勾选/取消勾选切换保活状态、系统内置常驻策略提示（显示“系统常驻”标签且禁止取消）
- 前置条件：系统存在正在运行且带有有效 Bundle ID 的第三方应用
- 常见故障现象：列表提示“没有检测到带 Bundle ID 的第三方应用” → 系统中只运行纯 CLI 脚本或守护进程；Docker / VPN 应用无法取消勾选 → 属于系统内置硬编码免打扰名单，无法被用户移除

---

### 可见控件与属性字典

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互说明 |
|---|---|---|---|---|---|
| 说明胶囊条 | `HStack` (带 shield 图标) | `AXGroup` | 顶部胶囊 | `"全场景常驻保活 · VPN 与 Docker 已默认免打扰"` | 纯信息展示 |
| 已保活区域标题 | `HStack` | `AXStaticText` | 标题标签 | `"已保活应用"` + 数量指示 `"(N)"` | 展示已加白数量 |
| 保活应用卡片 | `HStack` (Capsule 外观) | `AXGroup` | 轮播条目 | 14x14 图标 + 应用名 + 移除按钮 | 展示保活应用 |
| 移除保活按钮 | `Button` (Image: `xmark`) | `AXButton` | `help="移除保活"` | 叉号图标 | 单击移除对应应用的常用保活状态 |
| 空保活提示 | `Text(...)` | `AXStaticText` | 空状态占位 | `"暂无自定义常用应用，从下方列表中勾选添加"` | 当未添加常用时呈现 |
| 运行中区域标题 | `Text("从运行中选择")` | `AXStaticText` | 区域标题 | `"从运行中选择"` | 分组标题 |
| 快速筛选框 | `TextField` | `AXTextField` | 占位符 `"快速筛选..."` | 输入框 (宽 140pt) | 键入过滤运行中应用 |
| 运行中应用项 | `HStack` | `AXGroup` | 列表行 | 图标(22x22) + 应用名 + Bundle ID 文本 | 单击切换勾选状态 |
| 系统常驻标签 | `Text("系统常驻")` | `AXStaticText` | 胶囊标签 | `"系统常驻"` (紫色胶囊) | 标记系统内置免打扰策略 |
| 后台标签 | `Text("后台")` | `AXStaticText` | 胶囊标签 | `"后台"` (灰色胶囊) | 标记应用当前不在前台 |
| 保活复选框 | `Toggle` (.checkbox) | `AXCheckBox` | 行尾复选框 | 勾选/未勾选 | 勾选添加到常用，取消勾选移除 |
| 默认常驻只读提示 | `Text("默认常驻")` | `AXStaticText` | 行尾只读文字 | `"默认常驻"` (替代复选框) | 内置规则不可由用户更改 |

---

### 自动化测试代码参考

```applescript
-- AppleScript: 在常用面板中筛选并勾选保活应用
tell application "System Events"
    tell process "ResourceSteward"
        tell window 1
            click button "常用"
            delay 0.3
            -- 在快速筛选框输入应用名
            set value of text field 1 to "Slack"
            delay 0.3
            -- 切换勾选状态
            click checkbox 1 of scroll area 1
        end tell
    end tell
end tell
```

```swift
// XCUITest
let app = XCUIApplication(bundleIdentifier: "cc.resourcesteward")
let window = app.windows.firstMatch

window.buttons["常用"].click()

// 搜索并添加保活
let filterField = window.textFields["快速筛选..."]
filterField.click()
filterField.typeText("Safari\n")

let checkbox = window.checkBoxes.firstMatch
if checkbox.exists {
    checkbox.click()
}
```
