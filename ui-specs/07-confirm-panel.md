# 07. 浮动确认弹窗 (Confirm Prompt Panel)

## 浮动确认弹窗
- 用户称呼：确认弹窗、处理确认窗口、Jev 决策确认框、Confirm Dialog
- 入口：Level 0 模式下触发治理动作，或 Jev 批量决策建议生成时，系统居中弹出独立浮动窗口
- 关键选择器：`window "确认建议" of application "ResourceSteward"` (subrole=`AXStandardWindow`, 尺寸 380x220 pt)；单项标题: `AXStaticText` (`pending.action.confirmationTitle`)；批量标题: `AXStaticText "Jev 建议按当前负载处理这些应用"`；取消按钮: `button "取消"` / `button "暂不处理"` (快捷键: `Escape`)；执行按钮: `button "确认执行"` (快捷键: `Return`，退出动作为红色高亮)
- 子功能：单应用处理二次确认与破坏性动作安全警告、Jev 批量建议清单汇总展示、Helper 与主应用联动说明、全键盘快捷键支持（Esc 取消 / Enter 确认）、窗口关闭拦截（防止状态锁死）
- 前置条件：系统处于 Level 0（仅建议）模式，存在待处理的单项操作或 Jev 批次决策
- 常见故障现象：按快捷键没反应 → 弹窗失去焦点，点击弹窗重新激活即可；点击“确认执行”后目标应用没反应 → 目标应用已在前台被激活或用户正在编辑，安全熔断机制生效

---

### 可见控件与属性字典

#### 场景 A: 单个应用动作确认 (`pendingAction != nil`)

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互说明 |
|---|---|---|---|---|---|
| 浮动窗口容器 | `NSPanel` | `AXWindow` | `window "确认建议"` | 宽度 380pt，置顶浮动 (`.floating`) | 独立置顶对话框 |
| 动作标题 | `Text(pending.action.confirmationTitle)` | `AXStaticText` | 弹窗顶部标题 | `"确认降低进程优先级"` 或 `"确认退出应用"` | 粗体强调操作意图 |
| 应用进程信息 | `Text("<Name> · <N> 个进程")` | `AXStaticText` | 副标题 | 应用名称与旗下进程总数 | 提示影响范围 |
| Helper 联动警告 | `Text("Helper / Renderer 会随主应用...")` | `AXStaticText` | 条件提示 (`companionCount > 0`) | 说明多进程应用将联动处理，防止破坏网络或渲染 | 避免误判风险 |
| 动作详情解释 | `Text(pending.action.confirmationDetail)` | `AXStaticText` | 正文说明 | 动作后果详细解释（如退出后由系统自然回收） | 帮助用户决策 |
| 取消按钮 | `Button("取消")` | `AXButton` | `button "取消"` (快捷键: `Esc`) | `"取消"` | 取消操作并关闭弹窗 |
| 确认执行按钮 | `Button("确认执行")` | `AXButton` | `button "确认执行"` (快捷键: `Enter`) | `"确认执行"` (退出操作时为醒目红色) | 确认并执行后台指令 |

#### 场景 B: Jev 批量决策建议 (`pendingBatch != nil`)

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互说明 |
|---|---|---|---|---|---|
| 批次标题 | `Text("Jev 建议按当前负载处理这些应用")` | `AXStaticText` | 弹窗顶部标题 | `"Jev 建议按当前负载处理这些应用"` | 告知大模型推荐建议 |
| 原则说明文案 | `Text("降低优先级不会回收内存...")` | `AXStaticText` | 副标题提示 | 明确声明内存回收机制与降优先级差异 | 诚实降级告知 |
| 建议清单列表 | `ForEach(batch.items)` | `AXGroup` | 逐行展示 | 左侧应用名，右侧彩色动作标签 (`"降优先级"` / `"退出"`) | 批量审查候选列表 |
| 暂不处理按钮 | `Button("暂不处理")` | `AXButton` | `button "暂不处理"` (快捷键: `Esc`) | `"暂不处理"` | 放弃本次批次建议 |
| 确认执行按钮 | `Button("确认执行")` | `AXButton` | `button "确认执行"` (快捷键: `Enter`) | `"确认执行"` | 一并执行批量治理指令 |

---

### 自动化测试代码参考

```applescript
-- AppleScript: 响应确认弹窗
tell application "System Events"
    tell process "ResourceSteward"
        if exists window "确认建议" then
            tell window "确认建议"
                click button "确认执行"
            end tell
        end if
    end tell
end tell
```

```swift
// XCUITest
let app = XCUIApplication(bundleIdentifier: "cc.resourcesteward")
let dialog = app.windows["确认建议"]

if dialog.waitForExistence(timeout: 2.0) {
    let confirmBtn = dialog.buttons["确认执行"]
    XCTAssertTrue(confirmBtn.exists)
    confirmBtn.click()
}
```
