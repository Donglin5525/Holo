//
//  AIContextSection.swift
//  Holo
//
//  数据上下文注册表：每个数据域声明它在 chat / 意图识别两种上下文里的注入块。
//  单一事实源——块的格式、注入条件、专属路由规则都在 section 内维护，
//  AIUserContextMessageBuilder 只按注册顺序拼接（priority 供未来预算裁剪用）。
//  新增一类数据 = 新建一个 section 并注册，不再手写 builder 分支。
//

import Foundation

protocol AIContextSection {
    /// 稳定标识（如 "anniversaries"），用于诊断与排序
    var id: String { get }
    /// 预算裁剪优先级：数字越大越先被裁掉；同优先级按注册顺序
    var priority: Int { get }
    /// chat 上下文注入块（不含前后空行，builder 统一拼 "\n\n"）；nil = 本次不注入
    func chatBlock(_ context: UserContext) -> String?
    /// 意图识别上下文注入块（含该域的专属路由规则）；nil = 本次不注入
    func intentBlock(_ context: UserContext) -> String?
}

enum AIContextSectionRegistry {
    /// 注入顺序 = 数组顺序（chat 与意图识别两侧保持一致）；
    /// 新数据域在此追加一个 section
    static let sections: [any AIContextSection] = [
        AnniversaryContextSection(),
        DataCoverageContextSection(),
        RecentLinkedTaskContextSection(),
    ]
}

// MARK: - 纪念日

struct AnniversaryContextSection: AIContextSection {
    let id = "anniversaries"
    let priority = 100

    func chatBlock(_ context: UserContext) -> String? {
        guard !context.anniversaryLines.isEmpty else { return nil }
        let lines = context.anniversaryLines.map { "- \($0)" }.joined(separator: "\n")
        return "## 纪念日\n\n\(lines)"
    }

    func intentBlock(_ context: UserContext) -> String? {
        // 纪念日事实清单：让意图识别知道「X的生日/纪念日」是已有数据的事实问答，
        // 输出 query 走对话回复（回复上下文含同一份清单），而不是因不认识而 clarification。
        guard !context.anniversaryLines.isEmpty else { return nil }
        let lines = context.anniversaryLines.map { "- \($0)" }.joined(separator: "\n")
        var block = "--- 纪念日 ---"
        block += "\n\(lines)"
        block += "\n规则：用户询问某个纪念日的日期或倒计时（如「妈妈生日是哪天/还有多久」）属于事实问答，输出 mode=query、intent=query，不要 clarification，也不要 flexible_data_query（纪念日不是交易数据）。"
        return block
    }
}

// MARK: - 数据覆盖度

struct DataCoverageContextSection: AIContextSection {
    let id = "dataCoverage"
    let priority = 200

    func chatBlock(_ context: UserContext) -> String? {
        guard let coverage = context.dataCoverage, coverage.level != .rich else { return nil }
        var block = "--- 数据覆盖度 ---"
        block += "\n\(coverage.reason)"
        if !coverage.missingSources.isEmpty {
            let missing = coverage.missingSources.map { $0.displayName }.prefix(3)
            block += "\n缺失来源：\(missing.joined(separator: "、"))"
        }
        return block
    }

    func intentBlock(_ context: UserContext) -> String? {
        // 意图识别阶段只保留数据覆盖度风险提示，避免任务/想法/目标等无关上下文干扰 Router。
        guard let coverage = context.dataCoverage, coverage.level != .rich else { return nil }
        let availability = coverage.level == .partial ? "部分可用" : "暂无"
        var block = "--- 数据覆盖度提示 ---"
        block += "\n当前用户数据\(availability)：\(coverage.reason)"
        block += "\n处理意图时请注意数据完整性，缺失字段需向用户确认。"
        return block
    }
}

// MARK: - 最近对话关联的任务（「备忘单」）

struct RecentLinkedTaskContextSection: AIContextSection {
    let id = "recentLinkedTask"
    let priority = 300

    func chatBlock(_ context: UserContext) -> String? {
        // 备忘单只服务意图识别（modify_task_items 判断依据），chat 上下文不注入
        nil
    }

    func intentBlock(_ context: UserContext) -> String? {
        // 仅当确实存在最近关联任务时注入，供 modify_task_items 意图识别——
        // 用户对上文任务增删条目时据此判断。
        guard let recent = context.recentLinkedTask else { return nil }
        var block = "--- 最近对话关联的任务 ---"
        block += "\n- 任务：\(recent.title)"
        if !recent.itemTitles.isEmpty {
            let shown = recent.itemTitles.prefix(15).joined(separator: "、")
            let suffix = recent.itemTitles.count > 15 ? "等共 \(recent.itemTitles.count) 项" : ""
            block += "\n- 现有条目：\(shown)\(suffix)"
        } else {
            block += "\n- 现有条目：（暂无）"
        }
        block += "\n规则：仅当用户明确针对上面这个最近的任务补充/删除/替换条目时，用 modify_task_items（填 addItems 新增、removeItems 删除，removeItems 必须引用现有条目的确切名称）；用户不是针对这个任务时不要使用。"
        return block
    }
}
