# 场景资源管家（Resource Steward）

macOS 菜单栏里的 **Context-aware resource manager**。

后台软件会一直占着 CPU 和内存。这个工具根据你定义的工作场景，判断哪些进程**现在不重要**，并在你确认后降低优先级、冻结或请求退出。

它**不能**直接压缩或回收其他进程的内存。macOS 没有这样的公开 API。界面里的「预计可释放」是估算：冻结或退出之后，由系统自然回收。

## 能做什么

- 菜单栏常驻，展示内存压力、RAM / Compressed / Swap、整机 CPU 与 GPU 占用
- 按工作场景给进程打分（空闲、内存、可重启、是否属于当前场景、是否在前台）
- 建议动作：降低 CPU 优先级、冻结（`SIGSTOP`）、请求退出
- v1 默认只建议，点「应用建议」并确认后才执行
- 退出管家**不会**自动解冻；冻结名单保存在本地，下次启动会按 PID 重新暂停
- 全部数据留在本机 SQLite，无网络上传

## 不能做什么

| 能力 | 是否支持 |
|---|---|
| 展示 Memory Pressure / RAM / Swap / Compressed | 是 |
| 展示 per-process 内存 / CPU | 是 |
| 判断当前工作场景 | 是（规则匹配） |
| 降低优先级 / 冻结 / 退出 | 是（需确认） |
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
./scripts/package-app.sh         # 生成 dist/ResourceSteward.app
open dist/ResourceSteward.app
```

开发时也可以：

```bash
make run
# 或
swift run ResourceSteward
```

首次启动会显示能力边界说明。点击菜单栏芯片图标打开面板。

## 使用

1. 在 **场景** 里勾选正在运行的 App（含后台），创建例如「编程」「娱乐」。
2. 管家用最近 N 分钟的前台 App 与场景核心 App 做 Jaccard 匹配。
3. 在 **进程** 里查看建议，点「应用建议」并确认。
4. 已冻结的进程出现在列表顶部，可随时恢复。

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
