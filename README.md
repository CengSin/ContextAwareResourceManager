# 资源管家（ResourceSteward）

macOS 菜单栏资源管理工具：查看 CPU、内存和 GPU 占用，按当前负载与 Jev 判断建议降低后台应用优先级或请求正常退出。Level 0 确认后执行，Level 1 自动执行并通知。

降低优先级不会回收内存；退出后的回收由系统完成。本工具不直接压缩内存或清理显存，不读取窗口内容或剪贴板。

## 当前功能文档

- [页面与操作](feature/README.md)：看板、进程、常用、设置、确认与通知。
- [Jev 决策](feature/JevDecisionPipeline/README.md)：候选、模型评估、保护规则与节流。
- [诊断日志](feature/ResourceDiagnostics/README.md)：资源历史、决策证据与动作结果。

## 运行与检查

需要 macOS 13+、Swift 6 工具链。

```bash
./script/build_and_run.sh --verify
swift run StewardChecks
```

打包使用 `./scripts/package-app.sh`。应用数据位于 `~/Library/Application Support/ResourceSteward/`。启用 Jev 后，候选应用与负载观测会发送到设置中配置的模型服务；SQLite 和诊断日志保存在本机。

许可：[MIT](LICENSE)。
