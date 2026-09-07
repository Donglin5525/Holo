//
//  HoloContextPlanValidator.swift
//  Holo
//
//  方案草案的契约校验（实施方案 §8.3）。
//
//  - 来源：personalEvidence 必须有 sourceRefs 且指向输入情境；usedContextRefs
//    剔除不可用 ID；一般常识不得伪装已知用户状态或实时外部事实。
//  - 结构：依赖边必须无环且指向存在的 itemID；itemID 不得重复；
//    载荷不含自动执行指令（DTO schema 限定字段即防线）。
//  - 日期：相对时间保留相对表达；缺锚点不得伪造日历日期（confirmedDate 只能由
//    用户确认后由程序填，模型输出里的 confirmedDate 一律剥离）。
//  - 已完成事项：本周期实例状态为 done 的情境不得再产出对应待办。
//  - 校验失败允许一次修复再生成；不可把「JSON 恰好解析成功」当语义通过。
//
//  纯逻辑，可 standalone 编译。
//

import Foundation

nonisolated enum HoloContextPlanValidator {
    struct Finding: Equatable, Sendable {
        nonisolated enum Code: String, Equatable, Sendable {
            case emptyAnswer
            case personalEvidenceWithoutSource
            case unknownContextRef
            case danglingDependency
            case dependencyCycle
            case duplicateItemID
            case fabricatedConfirmedDate
            case suggestsCompletedOccurrence
            case tooManyUnknowns
            case selfDependency
        }

        var code: Code
        var detail: String
    }

    /// 校验并净化草案；返回净化后的草案与发现的问题。
    /// - Parameters:
    ///   - draft: 模型解析出的草案。
    ///   - availableContexts: 检索选取条目（id→条目）；不可用 ID 必须剔除。
    ///   - occursNow: 已在本周期完成的情境 contextID 集合（实例 status == done）。
    static func validate(
        draft: HoloContextPlanDraft,
        availableContexts: [HoloContextCatalogEntry]
    ) -> (sanitized: HoloContextPlanDraft, findings: [Finding]) {
        var sanitized = draft
        var findings: [Finding] = []
        let availableIDs = Set(availableContexts.map(\.payload.contextID))
        // 本周期已完成（实例 status == done）的情境：不得再产出对应待办。
        let completedContextIDs = Set(
            availableContexts
                .filter { $0.currentOccurrenceStatus == .done }
                .map(\.payload.contextID)
        )

        // 1) answerText 兜底必须存在（解析层已保证；这里防御）。
        if draft.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(Finding(code: .emptyAnswer, detail: "缺少可读回答"))
        }

        // 2) usedContextRefs 剔除不可用 ID。
        let validRefs = draft.usedContextRefs.filter { availableIDs.contains($0) }
        if validRefs.count != draft.usedContextRefs.count {
            findings.append(Finding(code: .unknownContextRef, detail: "剔除了 \(draft.usedContextRefs.count - validRefs.count) 个不可用引用"))
            sanitized.usedContextRefs = validRefs
        }

        // 3) personalEvidence 必须有指向输入情境的 sourceRefs。
        // 4) 模型输出的 confirmedDate 一律剥离（只有用户确认后程序才填）。
        // 5) 已完成实例的情境不得再产出待办。
        var seenItemIDs = Set<String>()
        var dedupedItems: [HoloContextPlanItem] = []
        for var item in draft.items {
            if item.basis == .personalEvidence {
                let validSources = item.sourceRefs.filter { availableIDs.contains($0) }
                if validSources.isEmpty {
                    // 个人证据缺失 → 降级为推断并保留（不静默删建议）。
                    item.basis = .inference
                    findings.append(Finding(code: .personalEvidenceWithoutSource, detail: "「\(item.title)」缺个人证据降级推断"))
                } else if validSources.count != item.sourceRefs.count {
                    item.sourceRefs = validSources
                }
            } else if !item.sourceRefs.isEmpty {
                item.sourceRefs = item.sourceRefs.filter { availableIDs.contains($0) }
            }
            if item.confirmedDate != nil {
                findings.append(Finding(code: .fabricatedConfirmedDate, detail: "剥离模型伪造的确认日期"))
                item.confirmedDate = nil
            }
            if seenItemIDs.contains(item.itemID) {
                findings.append(Finding(code: .duplicateItemID, detail: "重复 itemID \(item.itemID)"))
                continue
            }
            if item.kind == .task,
               !item.sourceRefs.isEmpty,
               item.sourceRefs.allSatisfy({ completedContextIDs.contains($0) }) {
                findings.append(Finding(code: .suggestsCompletedOccurrence, detail: "「\(item.title)」依据的情境本周期已完成，丢弃待办"))
                continue
            }
            seenItemIDs.insert(item.itemID)
            dedupedItems.append(item)
        }
        sanitized.items = dedupedItems

        // 6) 依赖边：指向存在的 itemID、无自环、无环。
        var edges: [HoloContextPlanDependencyEdge] = []
        for edge in draft.dependencyEdges {
            if edge.from == edge.to {
                findings.append(Finding(code: .selfDependency, detail: "自环 \(edge.from)"))
                continue
            }
            guard seenItemIDs.contains(edge.from), seenItemIDs.contains(edge.to) else {
                findings.append(Finding(code: .danglingDependency, detail: "悬空边 \(edge.from)→\(edge.to)"))
                continue
            }
            edges.append(edge)
        }
        if hasCycle(itemIDs: seenItemIDs, edges: edges) {
            // 成环时丢弃全部依赖边（保守：不猜哪条错）。
            findings.append(Finding(code: .dependencyCycle, detail: "依赖成环，丢弃全部边"))
            edges = []
        }
        sanitized.dependencyEdges = edges

        // 7) unknowns 上限（§8.2：最多 2 个真正影响安排的）。
        if draft.unknowns.count > 2 {
            findings.append(Finding(code: .tooManyUnknowns, detail: "截断到 2 个未知问题"))
            sanitized.unknowns = Array(draft.unknowns.prefix(2))
        }

        // 8) planEffects 引用净化：不可用情境 ID 剔除，防止变化陈述挂无效依据。
        if var effects = sanitized.planEffects {
            var removed = 0
            for index in effects.indices {
                let refs = effects[index].contextRefs ?? []
                let valid = refs.filter { availableIDs.contains($0) }
                if valid.count != refs.count {
                    removed += refs.count - valid.count
                    effects[index].contextRefs = valid
                }
            }
            if removed > 0 {
                findings.append(Finding(code: .unknownContextRef, detail: "方案影响剔除了 \(removed) 个不可用引用"))
                sanitized.planEffects = effects
            }
        }

        return (sanitized, findings)
    }

    /// DFS 环检测。
    static func hasCycle(itemIDs: Set<String>, edges: [HoloContextPlanDependencyEdge]) -> Bool {
        var adjacency: [String: [String]] = [:]
        for edge in edges {
            adjacency[edge.from, default: []].append(edge.to)
        }
        var visited = Set<String>()
        var inStack = Set<String>()
        func visit(_ node: String) -> Bool {
            guard !visited.contains(node) else { return false }
            visited.insert(node)
            inStack.insert(node)
            for next in adjacency[node] ?? [] where itemIDs.contains(next) {
                if inStack.contains(next) || visit(next) {
                    return true
                }
            }
            inStack.remove(node)
            return false
        }
        return itemIDs.contains { visit($0) }
    }

    /// 草案是否达到可交付门槛（致命问题为零）。
    static func isDeliverable(findings: [Finding]) -> Bool {
        findings.allSatisfy { finding in
            // 这些是净化性问题（已自动处理）；其余视为结构失败触发一次再生成。
            switch finding.code {
            case .unknownContextRef, .personalEvidenceWithoutSource,
                 .fabricatedConfirmedDate, .duplicateItemID, .tooManyUnknowns,
                 .danglingDependency, .selfDependency, .dependencyCycle,
                 .suggestsCompletedOccurrence:
                return true
            case .emptyAnswer:
                return false
            }
        }
    }
}
