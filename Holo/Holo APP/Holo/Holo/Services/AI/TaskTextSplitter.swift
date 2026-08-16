//
//  TaskTextSplitter.swift
//  Holo
//
//  语音/文本 → AI 拆解为 {标题, 子任务列表}
//  供任务页（TaskDetailView）的语音输入复用，让"说多个事项 → 自动拆成子任务"。
//  复用现有的意图识别通道（provider.parseUserInputBatch）+ SubtaskParser，
//  不新建后端 purpose，纯客户端调用。
//

import Foundation
import OSLog

/// 任务文本拆解结果
struct TaskSplitResult: Equatable {
    /// 主任务标题（AI 概括，兜底用原文）
    let title: String
    /// 拆出的子任务标题列表（少于 2 条时为空，遵循 SubtaskParser 规则）
    let subtasks: [String]
}

/// 语音/文本 → {标题, 子任务} 的轻量拆解服务。
///
/// 设计说明：照搬 `ThoughtVoiceSummaryProcessor` 的范式——自包含一个 AIProvider，
/// 调用方零注入成本。底层复用聊天页已在用的意图识别接口（`parseUserInputBatch`），
/// 拿到 create_task 意图里的 title / subtasks 字段，再用现成的 `SubtaskParser` 切分。
/// 不走 `ConversationCoordinator`/`IntentRouter`，因为那是"解析+落库"一体的重链路，
/// 新建任务页只需"解析"，落库交给 TaskDetailView 自己的保存流程。
@MainActor
final class TaskTextSplitter {
    private let provider: AIProvider
    private let logger = Logger(subsystem: "com.holo.app", category: "TaskTextSplitter")

    init(provider: AIProvider) {
        self.provider = provider
    }

    /// 便利构造：默认用生产环境的后端 AI Provider（与聊天页同一套接口）。
    convenience init() {
        self.init(provider: HoloBackendEnvironment.makeDefaultProvider())
    }

    /// 将一段文本拆解为主任务标题 + 子任务列表。
    ///
    /// 成功且识别为任务意图时返回拆解结果；若识别失败、非任务意图、或无子任务，
    /// 仍会尽力给出标题（兜底用原文），子任务为空数组。任何异常都向上抛，由调用方兜底。
    func split(_ text: String) async throws -> TaskSplitResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TaskSplitResult(title: "", subtasks: [])
        }

        // 复用现有意图识别通道：prompt 与字段契约（title/subtasks）已存在，无需改后端
        let batch = try await provider.parseUserInputBatch(trimmed, context: UserContext.empty)

        // 取第一个 create_task 项；非任务意图时退化为"标题=原文，无子任务"
        let createTaskItem = batch.items.first(where: { $0.intent == .createTask })
        guard let item = createTaskItem ?? batch.first else {
            return TaskSplitResult(title: trimmed, subtasks: [])
        }

        let data = item.extractedData ?? [:]
        let title = (data["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? trimmed
        let subtasks = SubtaskParser.parse(data["subtasks"])

        logger.debug("任务文本拆解完成：title=\(title, privacy: .public), 子任务数=\(subtasks.count)")
        return TaskSplitResult(title: title, subtasks: subtasks)
    }
}
