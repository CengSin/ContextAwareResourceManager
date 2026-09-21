# 06. 设置与 Jev AI 配置面板 (Settings Tab)

## 设置与 Jev AI 配置面板
- 用户称呼：设置 Tab、配置中心、Jev 配置、Settings
- 入口：主面板底部导航栏 → 点击第 3 个 Tab “设置”
- 关键选择器：`button "设置" of window 1`；授权单选按钮: `button` containing `"仅建议 (Level 0)"` / `button` containing `"半自动 (Level 1)"`；滑块: `slider 1` (AXRole=`AXSlider`, 范围 2-10s)；Jev 开关: `checkbox "启用 Jev 灰区判断"`；预设按钮: `button "TypeSafe"`, `button "OpenRouter"`；输入框: `text field "Base URL"`, `text field "模型"`, `secure text field "API Key"`；操作按钮: `button "保存到钥匙串"`, `button "清除 Key"`；存储路径: `AXStaticText` (SQLite 路径)
- 子功能：授权模式切换（Level 0 手动弹窗确认 vs Level 1 自动执行通知）、采样间隔微调滑块（2s ~ 10s）、Jev 大模型灰区决策总开关、供应商一键预设套用（TypeSafe / OpenRouter）、自定义 API 端点与模型名称、API Key 安全存取至系统 Keychain（支持保存与清除）、本地 SQLite 存储文件物理路径展示与复制
- 前置条件：macOS 钥匙串（Keychain）可用；网络可访问对应大模型 API 端点
- 常见故障现象：保存 API Key 报错 → 钥匙串访问权限被拒或沙盒阻拦；Jev 建议不出现 → Jev 开关未打开、API Key 未配置或网络不通时保留

---

### 可见控件与属性字典

#### 1. 授权级别区 (Authorization Level)

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互说明 |
|---|---|---|---|---|---|
| 分组标题 | `Text("授权级别")` | `AXStaticText` | 标题标签 | `"授权级别"` | 分组标题 |
| Level 0 单选项 | `Button` (Radio 风格) | `AXButton` / `AXRadioButton` | 包含 `"仅建议 (Level 0)"` | 标题 `"仅建议 (Level 0)"`，副文案 `"给出建议，弹出窗口由你确认后再执行"` | 点击切为手动弹窗确认模式 |
| Level 1 单选项 | `Button` (Radio 风格) | `AXButton` / `AXRadioButton` | 包含 `"半自动 (Level 1)"` | 标题 `"半自动 (Level 1)"`，副文案 `"自动执行降级或退出，通过通知栏告知；可随时在设置中切回"` | 点击切为半自动后台模式并请求通知权限 |
| 采样间隔滑块 | `Slider(range: 2...10)` | `AXSlider` | 对应标签 `"采样间隔（秒）"` | 2 ~ 10 秒调节，右侧展示当前值 (如 `"3"`) | 滑动调节监控采样频率 |

#### 2. Jev AI 配置区 (Jev Configuration)

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互说明 |
|---|---|---|---|---|---|
| Jev 灰区开关 | `Toggle("启用 Jev 灰区判断")` | `AXCheckBox` / `AXSwitch` | `checkbox "启用 Jev 灰区判断"` | 开关状态 | 开启或关闭大模型灰区判断 |
| TypeSafe 预设按钮 | `Button("TypeSafe")` | `AXButton` | `button "TypeSafe"` | `"TypeSafe"` (.small) | 一键填充 TypeSafe 默认端点与模型 |
| OpenRouter 预设按钮 | `Button("OpenRouter")` | `AXButton` | `button "OpenRouter"` | `"OpenRouter"` (.small) | 一键填充 OpenRouter 默认端点与模型 |
| Base URL 文本框 | `TextField("Base URL")` | `AXTextField` | 对应占位符 `"Base URL"` | 等宽字体文本框 | 设定 API 请求基地址 |
| 模型名称文本框 | `TextField("模型")` | `AXTextField` | 对应占位符 `"模型"` | 等宽字体文本框 | 设定大语言模型代号 |
| API Key 密码框 | `SecureField("API Key")` | `AXTextField` (Secure) | 对应占位符 `"API Key"` | 掩码输入框 | 输入大模型密钥（不落地明文） |
| 保存到钥匙串按钮 | `Button("保存到钥匙串")` | `AXButton` | `button "保存到钥匙串"` | `"保存到钥匙串"` | 将输入密钥存入系统 Keychain |
| 清除 Key 按钮 | `Button("清除 Key")` | `AXButton` | `button "清除 Key"` | `"清除 Key"` | 从系统 Keychain 删除已存密钥 |
| 密钥状态标签 | `Text(keyStatus)` | `AXStaticText` | 按钮右侧状态文案 | `"已配置钥匙串"` / `"未配置"` / 错误信息 | 提示密钥存储健康状态 |

#### 3. 数据存储区 (Data Storage)

| 控件名称 | 控件类型 (SwiftUI) | macOS AX 角色 | 定位方式 / 选择器 | 可视内容 / 文本 | 交互说明 |
|---|---|---|---|---|---|
| 存储路径文本 | `Text(coordinator.store.filePath)` | `AXStaticText` | 10pt 等宽文字 | 本地 SQLite 文件的绝对文件系统路径 | 支持选中并复制路径 |

---

### 自动化测试代码参考

```applescript
-- AppleScript: 切换授权级别为半自动
tell application "System Events"
    tell process "ResourceSteward"
        tell window 1
            click button "设置"
            delay 0.3
            -- 点击半自动 Level 1
            click (first button whose title contains "半自动")
        end tell
    end tell
end tell
```

```swift
// XCUITest
let app = XCUIApplication(bundleIdentifier: "cc.resourcesteward")
let window = app.windows.firstMatch

window.buttons["设置"].click()

// 切换 Jev 开关
let jevToggle = window.checkBoxes["启用 Jev 灰区判断"]
if !jevToggle.isSelected {
    jevToggle.click()
}

// 点击 TypeSafe 预设
window.buttons["TypeSafe"].click()
```

### Jev 批量决策状态

- 默认 TypeSafe 模型为 `jev-latest`。启用后，由算法筛选最多 5 个候选，先请求 Score/Noul 评估，再将结果传入 Choice 选择保留、降低优先级或退出。
- 切换 Jev 开关、模型或 API 端点会使批量结果失效；请求期间及请求失败时不产生可执行的批量建议。
- 同一候选与负载签名的结果最多复用 180 秒，前台应用或候选进程身份变化会重新评估。

- 两阶段问题、阈值及候选规则见 [JevDecisionPipeline](JevDecisionPipeline/README.md)。Level 0 展示判断并确认，Level 1 使用同一决策自动执行。
