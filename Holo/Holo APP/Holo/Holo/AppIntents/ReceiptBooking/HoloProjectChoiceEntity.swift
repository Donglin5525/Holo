//
//  HoloProjectChoiceEntity.swift
//  Holo
//
//  图片快捷指令自动记账 · 项目参数实体（2026-09-14 完整方案 §10.1/§22.2）
//
//  标识规则：project:none（不挂项目）/ project:explicit（按图片与附言明确匹配）/ project:<UUID>
//  查询规则：建议列表「不挂项目」第一项、「按图片/附言明确匹配」第二项，其后是进行中项目；
//  已完结/归档项目返回 isAvailable=false 快照；已删除不返回。
//

import AppIntents
import Foundation

struct HoloProjectChoiceEntity: AppEntity, Codable, Hashable, Sendable {
    var id: String
    var name: String
    /// 辅助信息（项目 emoji 等）
    var subtitle: String?
    var isAvailable: Bool

    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "财务项目")
    static let defaultQuery = HoloProjectChoiceQuery()

    static let noProject = HoloProjectChoiceEntity(
        id: "project:none",
        name: "不挂项目",
        subtitle: nil,
        isAvailable: true
    )

    static let explicitTextMatch = HoloProjectChoiceEntity(
        id: "project:explicit",
        name: "按图片/附言明确匹配",
        subtitle: "图里或附言写清项目名才会挂",
        isAvailable: true
    )

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: subtitle.map { "\($0)" }
        )
    }
}

struct HoloProjectChoiceQuery: EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [HoloProjectChoiceEntity] {
        var result: [HoloProjectChoiceEntity] = []
        var realProjectIDs: [String] = []
        for identifier in identifiers {
            if identifier == HoloProjectChoiceEntity.noProject.id {
                result.append(.noProject)
                continue
            }
            if identifier == HoloProjectChoiceEntity.explicitTextMatch.id {
                result.append(.explicitTextMatch)
                continue
            }
            if identifier.hasPrefix("project:") {
                realProjectIDs.append(identifier)
            }
        }
        guard !realProjectIDs.isEmpty else { return result }

        let projects = await MainActor.run {
            FinanceProjectRepository.shared.allProjects()
        }
        for identifier in realProjectIDs {
            guard let uuid = UUID(uuidString: String(identifier.dropFirst("project:".count))) else {
                continue
            }
            // 进行中 → 可用；仍存在但完结/归档 → 不可用快照；已删除（仓库层已过滤）→ 不返回
            let project = projects.first(where: { $0.id == uuid })
            guard let project else { continue }
            let active = project.statusEnum == .active
            result.append(HoloProjectChoiceEntity(
                id: identifier,
                name: project.name,
                subtitle: active ? nil : String(localized: "已结束"),
                isAvailable: active
            ))
        }
        return result
    }

    func suggestedEntities() async throws -> [HoloProjectChoiceEntity] {
        var suggestions: [HoloProjectChoiceEntity] = [.noProject, .explicitTextMatch]
        let projects = await MainActor.run {
            FinanceProjectRepository.shared.activeProjects()
        }
        for project in projects {
            suggestions.append(HoloProjectChoiceEntity(
                id: "project:\(project.id.uuidString)",
                name: project.name,
                subtitle: nil,
                isAvailable: true
            ))
        }
        return suggestions
    }

    func entities(matching string: String) async throws -> [HoloProjectChoiceEntity] {
        let all = try await suggestedEntities()
        guard !string.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func defaultResult() async -> HoloProjectChoiceEntity? {
        .noProject
    }
}
