# Agent 结果即时显示修复方案

## 产品结论

Agent 已经完成计算并保存结果，但当前 HoloAI 页面只留下头像和空白区域；退出后重新进入才显示卡片。这不是生成失败，而是当前消息的内存快照没有从“元数据不可用”切换到“元数据已加载”。用户会误以为 Agent 没有回答，因此属于结果交付链路的阻断问题。

修复后的产品契约是：Agent 返回结果后，同一个消息气泡必须在当前页面立即从加载态切换为深度分析卡片，不依赖页面重进、手动刷新或数据库重载。

## 根因

`ChatMessageRepository.finalizeMessage` 已经一次性写入最终文本、`isStreaming = false` 和 `agentResultJSON`，并同步更新 `ChatMessageViewData.agentResult`，但没有把快照的 `metadataState` 从初始 streaming 消息的 `.unavailable` 更新为 `.loaded`。

`MessageBubbleView` 发现结果存在后会进入 `AgentDeepAnalysisCard`；该卡片只有在 `metadataState == .loaded` 时才展示真实内容。于是当前页面形成“结果存在，但卡片 body 为空”的矛盾状态。重新进入页面后，轻量数据库加载会根据已保存的 `agentResultJSON` 重建 `.loaded`，所以卡片才出现。

## 设计决策

在 `finalizeMessage` 的同一次快照更新中设置 `metadataState = .loaded`。这是消息完成操作的一部分，因为该方法收到并解析了本次消息的全部结构化元数据；完成后快照不应继续表示“元数据不可用”。

不采用 UI 强制占位或延迟刷新：它们会掩盖状态不一致，也无法保证其他结构化结果即时出现。

## 数据流

1. Agent 完成并返回 `HoloRenderedAgentResult`。
2. `ChatViewModel` 调用 `finalizeMessage`。
3. Repository 在一次操作中保存最终文本、停止 streaming、写入 Agent JSON。
4. 同一次内存快照更新写入解码后的 Agent 结果，并设置 `metadataState = .loaded`。
5. `@Published messages` 触发当前 Chat 页面重绘，卡片立即展示。

## 兼容与失败边界

- 对普通文本、批处理卡片、账单分析同样成立：`finalizeMessage` 已经掌握完整元数据，完成后统一视为 loaded。
- Agent JSON 解码失败时仍保留 fallback 文本；不会用空卡片遮挡错误。
- 恢复路径 `finalizeAgentMessage` 已经设置 `.loaded`，保持不变。
- 不修改 Prompt、Agent 计算、后端或卡片视觉。

## 验证

- 新增 Repository 回归测试：从 streaming 快照开始，调用 `finalizeMessage` 后断言 `isStreaming == false`、`agentResult != nil`、`metadataState == .loaded`。
- 保留旧 JSON/结果渲染回归。
- 执行相关 standalone/test build，并运行 iOS Simulator 全工程构建。
- 手工验收：在 HoloAI 提问后停留当前页面，结果完成时卡片直接出现；无需退出重进。
