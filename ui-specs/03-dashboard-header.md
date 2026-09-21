# 03. 资源看板与面板外壳 (Dashboard & Shell)

## 资源看板与面板外壳
- 用户称呼：主面板、Dashboard、看板概览、主窗口顶底栏
- 入口：点击菜单栏图标（引导已完成状态下唤起）
- 关键选择器：`window 1 of application "ResourceSteward"` (subrole=`AXSystemDialog`)；模式标识: `AXStaticText "半自动"` / `AXStaticText "仅建议"`；Tab 导航: `button "进程"`, `button "常用"`, `button "设置"`；刷新按钮: `button` with AXHelp `"立即刷新"`；退出按钮: `button` with AXHelp `"退出管家（会自动解冻）"`
- 子功能：环形 RAM 表盘占用率展示、CPU/GPU/内存多维硬件指标柱状图、后台闲置应用释放估算与治理状态胶囊、三大功能 Tab 切换、一键强制立即刷新、安全退出应用（自动解冻受控进程）
- 前置条件：已完成新手引导（`hasCompletedOnboarding == true`）
- 常见故障现象：点击面板外部面板立即消失 → macOS 窗口式 MenuBarExtra 失去焦点默认自动关闭；GPU 数据显示破折号或“当前无法读取” → 系统无独立 GPU 或无 IOKit/Metal 读取权限

---

### 可见控件与属性字典

#### 1. 顶部栏 (Header)

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互说明 |
|---|---|---|---|---|---|
| 应用标题 | `Text("资源管家")` | `AXStaticText` | 标题标签 | `"资源管家"` + 芯片图标 | 纯展示 |
| 授权模式胶囊 | `Text("半自动")` / `Text("仅建议")` | `AXStaticText` | 模式胶囊 | `authorizationLevel == .sceneSwitch` ? "半自动" : "仅建议" | 视觉状态指示 |
| 环形内存表盘 | `Circle().trim(...)` | `AXGroup` | 仪表盘左侧卡片 | 居中显示 `"RAM"` + 百分比数字 (`XX%`) + 压力文字标签 | 实时更新 |
| CPU 统计条 | `MinimalStatBar(title: "CPU")` | `AXGroup` | `title="CPU"` | 百分比数字、细胶囊进度条、副文案 `"用户 X% · 系统 Y%"` | 实时更新 |
| GPU 统计条 | `MinimalStatBar(title: "GPU")` | `AXGroup` | `title="GPU"` | 百分比数字、细胶囊进度条、副文案 (名称与显存占用) | 实时更新 |
| 内存统计条 | `MinimalStatBar(title: "内存")` | `AXGroup` | `title="内存"` | 百分比数字、细胶囊进度条、副文案 `"已用 X / Y · 压缩 Z"` | 实时更新 |
| 负载治理与释放估算胶囊 | `HStack` (带 sparkles/ecg 图标) | `AXGroup` | 仪表盘下方胶囊 | `"发现闲置后台应用，预计可释放 X MB"` 或 Jev 负载治理状态文案 | 动态显隐与文案 |

#### 2. 底部栏 (Footer)

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互说明 |
|---|---|---|---|---|---|
| 进程 Tab 按钮 | `Button(PanelTab.processes.title)` | `AXButton` | `button "进程"` (`app.buttons["进程"]`) | `"进程"` | 点击切换至进程列表页 |
| 常用 Tab 按钮 | `Button(PanelTab.favorites.title)` | `AXButton` | `button "常用"` (`app.buttons["常用"]`) | `"常用"` | 点击切换至常用保活页 |
| 设置 Tab 按钮 | `Button(PanelTab.settings.title)` | `AXButton` | `button "设置"` (`app.buttons["设置"]`) | `"设置"` | 点击切换至设置配置页 |
| 手动刷新按钮 | `Button` (Image: `arrow.clockwise`) | `AXButton` | `help="立即刷新"` | 旋转箭头图标 | 点击调用 `coordinator.refresh()` |
| 退出程序按钮 | `Button` (Image: `power`) | `AXButton` | `help="退出管家（会自动解冻）"` | 电源关机图标 | 点击调用 `NSApp.terminate(nil)` |

---

### 自动化测试代码参考

```applescript
-- AppleScript: 点击切换选项卡与刷新
tell application "System Events"
    tell process "ResourceSteward"
        tell window 1
            -- 切换到常用 Tab
            click button "常用"
            delay 0.5
            -- 切换到设置 Tab
            click button "设置"
            delay 0.5
            -- 切换回进程 Tab
            click button "进程"
            -- 点击刷新按钮
            click (every button whose help is "立即刷新")
        end tell
    end tell
end tell
```

```swift
// XCUITest
let app = XCUIApplication(bundleIdentifier: "cc.resourcesteward")
let window = app.windows.firstMatch

// 点击 Tab
window.buttons["常用"].click()
XCTAssertTrue(window.staticTexts["已保活应用"].exists)

window.buttons["设置"].click()
XCTAssertTrue(window.staticTexts["授权级别"].exists)

window.buttons["进程"].click()
XCTAssertTrue(window.searchFields.firstMatch.exists)
```

### Jev 治理状态

底栏治理状态显示候选与请求阶段：负载未达到条件、持续负载观察、无可治理应用、候选未满足空闲/占用条件、评估阶段 1/2 或 2/2、错误等待重试、动作后观察。黄色压力不等同于存在可退出候选；失败冷却期间显示失败原因。详见 [JevDecisionPipeline](JevDecisionPipeline/README.md)。
