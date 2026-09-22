# ResourceDiagnostics：资源历史与决策回溯

## 入口与职责

应用启动后自动记录，无新增界面控件或权限开关。目录：`~/Library/Application Support/ResourceSteward/Diagnostics/`。文件为 `events.jsonl` 和 `events.1.jsonl` 至 `events.7.jsonl`；每行一个 JSON，UTC Unix 秒时间戳。`session_id` 区分应用运行周期，`request_id` 串联 Jev 两阶段、审核与执行，`action_id` 串联动作及后续观测。

- `Sources/ResourceStewardCore/Features/ResourceDiagnostics/DiagnosticLog.swift`：串行后台写入、文件权限、轮转与过期删除。
- `ResourceHistory.swift`：30 秒资源历史和压力变化记录。
- `ActionDiagnostics.swift`：动作请求、接口返回与进程后续观测。
- 对应行为检查：`Sources/StewardChecks/Features/ResourceDiagnostics/`。
- Jev 结构化证据位于 `Features/JevDecisionPipeline/JevDiagnostics.swift`；协调器只负责提供采样与执行接线。

## 记录与查询字段

| event | 内容 |
|---|---|
| `app_started` / `app_stopping` | PID、应用版本、构建时间/修订（构建脚本提供时）、OS、系统 uptime；没有 stopping 不能单独证明崩溃 |
| `settings_saved` / `credential_updated` | 授权级别、采样间隔、Jev 开关/可用性、常用 bundle ID；凭据只记是否配置 |
| `resource_sample` | RAM、压缩、wired、free、purgeable、Swap 存量/累计页数/变化速率、CPU、GPU、驱动显存计数器、前台 bundle、最多 12 个主要应用与硬门排除原因 |
| `jev_selection` | 没有发起请求的原因、候选资源与未入选原因、请求等待剩余秒数、是否仍有旧网络批次 |
| `jev_request_start` | 实际送入的负载、候选身份/资源、允许动作和模型标识，不含应用名称或完整请求体 |
| `jev_stage_start` / `jev_stage_complete` | 阶段、HTTP 状态和延时；第一阶段开始由 request_start 表示 |
| `jev_assessment` | 第一阶段 Score、confidence、概率分布和各应用两项 Noul |
| `jev_decision` | 第二阶段受支持的原始 Choice、有效 confidence、本地最终动作与审核原因；非法自由文本不落盘 |
| `jev_request_complete` / `jev_response_discarded` / `jev_request_failed` | 当前上下文是否接受结果、过期丢弃、失败阶段和安全错误码 |
| `execution_gate` | 执行前复核保护规则、近期前台、已降优先级、应用冷却、证据及授权级别 |
| `confirmation_*` | 显示、取消、失效、确认后实际匹配/成功数量 |
| `action_requested` / `action_result` | 来源（手动确认/Jev 确认/自动）、进程代次、请求动作、接口是否成功及本地结果说明 |
| `action_observed` | 动作至少 5 秒、30 秒后的下一次采样：原进程仍运行/退出/PID 复用/无法确认，目标内存/CPU 与系统用量变化 |
| `action_observation_incomplete` / `storage_error` | 应用停止时观测未完成、数据库写入失败操作及错误码 |

资源记录每 30 秒一次，系统事件压力或推断压力变化时立即记录。Swap 速率取相邻采样的计数器差值；超过 60 秒的采样间隔、计数器回退和无有效内存采样时为 null。GPU 可用性与显存计数器可用性分开记录；GPU 为已有采样器的 20 秒缓存/中位数，附采样时间。共享/统一内存驱动计数器不等同独立显存容量。

`os_pressure_event` 是最后一次 DispatchSource 事件，初始化为 normal；`effective_pressure` 是 app 合成压力，`pressure_reasons` 给出触发来源。两者不能混称 OS 压力。采样失败使用 availability 标志，不能把零数值认定为资源充足。

目标退出只有 PID 明确不存在时标记 exited；身份读取失败为 unknown，PID 换代为 pid_reused。动作后采样可能延迟（休眠/系统繁忙），记录真实 elapsed_seconds。内存差值只是观测，不承诺为该动作释放的容量；不跟踪重新启动的新进程。正常退出接口成功只代表请求已发送，未保存提示导致应用继续运行会在后续记录中体现。尚未完成的观测在异常退出后可能没有结束事件。

## 保留与隐私

每份最多 8 MiB，含当前文件共最多 8 份（64 MiB）。写入时每小时检查一次，删除最后修改时间超过 7 天的文件；容量先达到时先轮转，因此不保证完整保留 7 天。没有新写入时不主动清理。诊断文件权限 0600，新建目录 0700。仅保存在本机；不上传资源历史。

不记录 API Key、Authorization、端点 URL、窗口/文档内容、完整请求或服务端响应正文。记录应用 bundle ID、PID 与本地执行结果。非法模型文本仅记录验证原因，不原样写入。文件无法写入或单条过大/非 JSON 时，通过统一日志子系统 `cc.resourcesteward.diagnostics` 每分钟最多一次报告存储错误，不影响治理。`StewardChecks` 关闭正式文件日志，轮转和证据测试仅写临时目录。

## 故障排查与验证

故障后先保留 Diagnostics 整个目录、`jev-reclaim.log*` 和系统 DiagnosticReports。先按时间定位 resource_sample，再按 session_id/request_id/action_id 查看候选、模型评估、本地审核及执行效果。目录为空时检查应用版本及统一日志中的 diagnostics_error；日志缺口也可能是应用关闭、休眠或系统卡顿。

验证：`swift run StewardChecks --diagnostics`、`swift run StewardChecks --jev-pipeline`、全量 StewardChecks、`swift build`、Swift 注释检查与 `git diff --check`。临时文件检查覆盖容量轮转、过期、JSON 完整性、隐私过滤、压力变化记录、缺失 GPU、进程退出和 PID 复用；不操作真实用户进程。实际启动后核对 app_started/settings_saved/resource_sample 落盘。
