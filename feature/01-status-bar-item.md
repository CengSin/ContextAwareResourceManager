# 01. 菜单栏状态指示器 (Status Bar Item)

## 菜单栏状态指示器
- 用户称呼：菜单栏图标、状态栏图标、常驻托盘图标、Status Bar Item、menu icon
- 入口：macOS 顶部系统菜单栏（Menu Bar 2 托盘区）；点击展开主面板
- 关键选择器：`menu bar item 1 of menu bar 2 of application "ResourceSteward"`；AXRole=`AXMenuBarItem`；AXTitle=`"memorychip"`；XCUITest: `app.statusItems.firstMatch`
- 子功能：单体菜单栏图标展示、单击唤起或收起主面板
- 前置条件：应用已启动并常驻后台（`ResourceSteward.app` 正在运行）
- 常见故障现象：图标未在顶栏出现 → 刘海屏遮挡或右侧托盘图标过多被系统折叠，需借助 Bartender/Ice 查看；点击无反应 → 应用主事件循环阻塞

---

### 可见控件与属性字典

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互事件与视觉说明 |
|---|---|---|---|---|---|
| 菜单栏图标 (Menu Icon) | `MenuBarExtra` / `Image(systemName: "memorychip")` | `AXMenuBarItem` | `menu bar item 1 of menu bar 2 of application "ResourceSteward"` | SF Symbol 芯片图标 (`memorychip`) | 位于 macOS 屏幕顶部托盘栏（非普通桌面窗口内控件）。真机界面上为**单一图标**，单击切换展开/收起主面板。 |

> [!NOTE]
> **状态栏入口说明**：本应用为 `LSUIElement` 辅助应用，仅在屏幕顶部系统托盘中以单体芯片图标存在，无 Dock 栏图标及桌面常驻窗口。配备刘海屏的设备在图标过多时可能被系统折叠隐藏。

### 自动化测试代码参考

```applescript
-- AppleScript: 点击展开菜单栏面板
tell application "System Events"
    tell process "ResourceSteward"
        click (menu bar item 1 of menu bar 2)
    end tell
end tell
```

```swift
// XCUITest
let app = XCUIApplication(bundleIdentifier: "cc.resourcesteward")
let statusItem = app.statusItems["memorychip"]
XCTAssertTrue(statusItem.exists)
statusItem.click()
```
