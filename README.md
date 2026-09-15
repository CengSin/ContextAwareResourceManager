# 场景资源管家（Resource Steward）

macOS 菜单栏里的 **Context-aware resource manager**。

后台软件会一直占着 CPU 和内存。这个工具根据你定义的工作场景，判断哪些进程**现在不重要**，并在你确认后降低优先级、冻结或请求退出。

它**不能**直接压缩或回收其他进程的内存。macOS 没有这样的公开 API。界面里的「预计可释放」是估算：冻结或退出之后，由系统自然回收。

## 能做什么

- 菜单栏常驻，展示内存压力、RAM / Compressed / Swap、整机 CPU 与 GPU 占用
- 按工作场景给进程打分（空闲、内存、可重启、是否属于当前场景、是否在前台）
- Chrome 等应用的 Helper / Renderer 并入主应用，不会单独降级（单独处理会打断开链接等 IPC）
- 建议动作：降低 CPU 优先级、冻结（`SIGSTOP`）、请求退出
- 默认只建议，点「应用建议」并确认后才执行
- 可在 **常用** 里勾选跨场景保活的 App：任何场景都不会降低优先级、冻结或退出。VPN/代理、OrbStack / Docker 等已默认常驻
- 可在设置中开启 **切场景半自动（Level 1）**：切换到已识别场景并稳定约 15 秒后，自动降低优先级或冻结离场景应用；退出建议会改成冻结。未分类不触发。VPN/代理（Shadowrocket 等）、容器/虚拟机（OrbStack、Docker 等）、菜单栏常驻工具和常用应用不会冻结；`python` 这类没有 App bundle 的进程也不会被半自动处理
- 按当前时段记录场景切换习惯，并在「场景」页展示接下来最常去的场景（不据此改打分）
- 退出管家时自动解冻，并恢复已降低的优先级
- 全部数据留在本机 SQLite，无网络上传

## 不能做什么

| 能力 | 是否支持 |
|---|---|
| 展示 Memory Pressure / RAM / Swap / Compressed | 是 |
| 展示 per-process 内存 / CPU | 是 |
| 判断当前工作场景 | 是（规则匹配） |
| 切场景半自动处理离场景 App | 是（设置里开启 Level 1） |
| 按时间记录场景切换习惯 | 是（仅展示） |
| 降低优先级 / 冻结 / 退出 | 是（默认需确认；Level 1 切场景时可自动冻结/降优先级） |
| **直接压缩其他进程的内存页** | 否，永久不可行 |
| 读取其他 App 的窗口内容或剪贴板 | 否 |

## 要求

- macOS 13+
- Swift 6 工具链（Xcode 或 Command Line Tools）
- 不走 Mac App Store 沙盒（沙盒会限制向其他进程发信号）

## 构建

```bash
swift run StewardChecks          # 核心算法与本机采样检查
swift build -c release
./scripts/package-app.sh                 # 生成 dist/ResourceSteward.app
./scripts/package-app.sh --version 1.1.0 # 写入 CFBundleShortVersionString
./scripts/package-app.sh 1.1.0 --build 12
open dist/ResourceSteward.app
```

`make app VERSION=1.1.0 BUILD=12` 同样可以把版本写进包里。不传时用 `Resources/Info.plist` 里的值；CI 里 `--build` 默认是 GitHub run number。

每次 push 到 `main` 时，GitHub Actions 会在 macOS 上跑 StewardChecks、打包，并把 `ResourceSteward-<version>.zip` 更新到 Releases 的 **Latest build**（预发布，tag 为 `latest`）。打 `v*` 标签（例如 `v1.1.0`）会用标签版本号打包，并创建一个正式 GitHub Release，zip 挂在 Release 资源里。Actions run 的 Artifacts 里也能下载同一份 zip，保留 14 天。

开发时也可以：

```bash
make run
# 或
swift run ResourceSteward
```

首次启动会显示能力边界说明。点击菜单栏芯片图标打开面板。

## 使用

1. 在 **场景** 里勾选正在运行的 App（含后台），创建例如「编程」「娱乐」。
2. 若有任何场景都不该动的软件（数据库、本机服务），到 **常用** 里勾选。
3. 管家用最近 N 分钟的前台 App 与场景核心 App 做 Jaccard 匹配。
4. 在 **进程** 里查看建议，点「应用建议」并确认。
5. 已冻结的进程出现在列表顶部，可随时恢复。
6. 若要在切场景时自动处理离场景应用，到 **设置** 打开「切场景时半自动」。

数据位置：`~/Library/Application Support/ResourceSteward/resource-steward.sqlite`

## 架构

```
Menu Bar UI (SwiftUI)
        │
Application Coordinator
   ┌────┼────┬─────────┬──────────┐
Context  System  Workspace  Reclaim   Action
Collector Monitor Matcher   Scorer    Executor
               │
          Local Store (SQLite)
```

详见 [context-aware-resource-agent-spec.md](context-aware-resource-agent-spec.md)。

## 许可

[MIT](LICENSE)。使用、修改和再分发时请保留版权与许可声明。
