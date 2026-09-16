//
//  HoloAccountChoiceEntity.swift
//  Holo
//
//  图片快捷指令自动记账 · 账户参数实体（2026-09-14 完整方案 §10.1/§22.2）
//  Sendable 纯值快照：Account (NSManagedObject) 绝不跨 AppIntent 并发边界。
//
//  标识规则：account:auto（自动识别）/ account:<UUID>（真实账户）
//  查询规则：建议列表「自动识别」第一项，其后按 FinanceRepository.getAccounts 现有顺序；
//  已归档账户返回 isAvailable=false 快照；已删除账户不返回 → 系统要求重新选择，绝不静默换对象。
//

import AppIntents
import Foundation

struct HoloAccountChoiceEntity: AppEntity, Codable, Hashable, Sendable {
    /// account:auto 或 account:<UUID>
    var id: String
    var name: String
    /// 辅助信息（账户类型等；同名账户靠它区分）
    var subtitle: String?
    /// 归档/失效快照：仍显示但标记不可用，运行时由门禁转复核
    var isAvailable: Bool

    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "账户")
    static let defaultQuery = HoloAccountChoiceQuery()

    static let automatic = HoloAccountChoiceEntity(
        id: "account:auto",
        name: "自动识别",
        subtitle: "按支付渠道与尾号匹配",
        isAvailable: true
    )

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: subtitle.map { "\($0)" }
        )
    }
}

struct HoloAccountChoiceQuery: EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [HoloAccountChoiceEntity] {
        var result: [HoloAccountChoiceEntity] = []
        var candidates: [(id: String, uuid: UUID)] = []
        for identifier in identifiers {
            if identifier == HoloAccountChoiceEntity.automatic.id {
                result.append(.automatic)
                continue
            }
            guard identifier.hasPrefix("account:"),
                  let uuid = UUID(uuidString: String(identifier.dropFirst("account:".count))) else {
                continue
            }
            candidates.append((identifier, uuid))
        }
        guard !candidates.isEmpty else { return result }

        // 全量对象（含归档，不含已删除）：归档 → 不可用快照；删除 → 不返回（参数失效，需重选）
        let accounts = await MainActor.run {
            FinanceRepository.shared.getAccounts(includeArchived: true)
        }
        for candidate in candidates {
            guard let account = accounts.first(where: { $0.id == candidate.uuid && $0.deletedAt == nil }) else {
                continue
            }
            result.append(HoloAccountChoiceEntity(
                id: candidate.id,
                name: account.name,
                subtitle: account.isArchived ? String(localized: "已归档") : nil,
                isAvailable: !account.isArchived
            ))
        }
        return result
    }

    func suggestedEntities() async throws -> [HoloAccountChoiceEntity] {
        var suggestions: [HoloAccountChoiceEntity] = [.automatic]
        let accounts = await MainActor.run {
            FinanceRepository.shared.getAccounts(includeArchived: false)
        }
        for account in accounts {
            suggestions.append(HoloAccountChoiceEntity(
                id: "account:\(account.id.uuidString)",
                name: account.name,
                subtitle: nil,
                isAvailable: true
            ))
        }
        return suggestions
    }

    func entities(matching string: String) async throws -> [HoloAccountChoiceEntity] {
        let all = try await suggestedEntities()
        guard !string.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func defaultResult() async -> HoloAccountChoiceEntity? {
        .automatic
    }
}
