# Holo 架构

## 产品数据流

Holo 的记账、待办、习惯、想法和健康模块优先把数据保存在本机。用户主动启用 iCloud 后，允许同步的数据由个人 CloudKit 容器处理；健康派生记忆默认不进入跨设备同步。

HoloAI 通过工具目录读取最小必要数据。工具结果必须区分成功、空数据、部分数据、锁屏不可读、权限不可用与读取错误，并携带实际覆盖范围和截断信息，避免把“没读到”解释成“没有”。

## 运行组件

1. iOS App：SwiftUI、Core Data、HealthKit、CloudKit、BackgroundTasks、DeviceCheck/App Attest。
2. 本地 Agent：规划、工具执行、证据账本、结论校验和可恢复 Job 状态。
3. HoloBackend：Hono API、SQLite、Prompt Registry、AI/ASR Provider、App Attest 会话、限流和发布状态。
4. 官网：Vite + React，提供产品说明与独立合规页面。

## 启动分层

- `critical`：通知与系统后台任务注册、Core Data 预热等首屏前必要工作。
- `afterFirstFrame`：迁移、Repository 恢复与一次性调和，由 `HoloStartupCoordinator` 保证进程内幂等。
- `backgroundBestEffort`：可延后且允许系统中断的快照、洞察和整理任务；不能被描述为必达。

## 关键接口

- 存活：`GET /v1/live`
- 就绪：`GET /v1/ready`
- 发布身份：`GET /v1/release/status`
- AI：`POST /v1/ai/chat/completions`
- ASR：`POST /v1/asr/transcriptions`
- App Attest：`POST /v1/app-attest/challenge|attest|assert`
