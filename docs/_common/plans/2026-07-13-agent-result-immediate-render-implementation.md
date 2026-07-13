# Agent 结果即时显示 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. 项目禁止 subagent，直接在当前唯一工作副本中执行。

**Goal:** Agent 完成后让当前 HoloAI 页面立即显示深度分析卡片，不再依赖退出重进。

**Architecture:** 保持 Core Data 与内存快照的原子完成语义一致。`finalizeMessage` 在写入最终内容和结构化元数据后，同步把 `ChatMessageViewData.metadataState` 设置为 `.loaded`，让现有 SwiftUI 卡片条件立即成立。

**Tech Stack:** Swift、SwiftUI、Combine、Core Data、XCTest、xcodebuild。

---

### Task 1: 用回归测试锁定消息完成状态

**Files:**
- Modify: `Holo/Holo APP/Holo/HoloTests/Models/ChatMessageRepositoryCacheRecoveryTests.swift`

**Step 1: 写失败测试**

创建 streaming assistant 消息，调用 `finalizeMessage` 写入一个可编码的 `HoloRenderedAgentResult`，断言当前 `repo.messages` 中同一消息满足：

- `isStreaming == false`；
- `agentResult != nil`；
- `metadataState == .loaded`。

**Step 2: 验证测试先暴露旧行为**

通过源码审计确认旧实现没有更新 `metadataState`；使用 `xcodebuild build-for-testing` 编译测试 target。当前测试宿主可能因 CloudKit entitlement 在启动前崩溃，不能把未执行用例称为测试通过。

### Task 2: 原子修复快照状态

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Data/Repositories/ChatMessageRepository.swift`

**Step 1: 最小实现**

在 `finalizeMessage` 的单次 `updateSnapshot` 闭包末尾写入：

```swift
snapshot.metadataState = .loaded
```

不添加延迟刷新、不重新读取数据库、不修改 UI 条件。

**Step 2: 静态回归审计**

确认 `finalizeAgentMessage` 仍设置 `.loaded`；确认 loading、失败与恢复路径没有被改变。

### Task 3: 验证、记录与交付

**Files:**
- Modify: `CHANGELOG.md`

**Step 1: 编译测试代码**

运行独立 DerivedData 的 `xcodebuild build-for-testing`，期望 `TEST BUILD SUCCEEDED`。

**Step 2: 全工程构建**

运行 iOS Simulator `xcodebuild build`，期望 `BUILD SUCCEEDED`。

**Step 3: 更新 CHANGELOG**

记录用户可见修复：Agent 结果完成后在当前页面即时出现，无需退出重进。

**Step 4: scoped commit 与 push**

只暂存 Repository、对应测试、实施计划和 CHANGELOG；核对 origin 为 `git@github.com:Donglin5525/Holo.git`，提交并推送 `main`。不包含工作区其他改动。
